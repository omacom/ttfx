//! voronoi: the text crystallizes into a stained-glass window. Seeds spark
//! in the letters and around them, panes of jewel glass grow outward from
//! them and meet in bright leaded seams, and the logo stays etched, glowing,
//! in the glass while the window breathes and a beam of light sweeps across
//! it. Then the window breaks pane by pane from the outside in: each pane's
//! seams crack white, its glass splinters into shards and the shards are
//! drawn into the letters, which flash as they land and keep their pane's
//! color, until a glint sweeps across and anneals them into the final text.
//! Finally, a slanted cathedral sunbeam glides behind the finished lettering,
//! lighting each letter like backlit stained glass in its pane's jewel hue
//! while ghostly leaded seams and panes glow briefly around the logo before
//! fading cleanly to black.
//!
//! Original effect by Lukas Innig (@derluke), https://github.com/derluke/ttfx, MIT.
//!
//! Rewritten for the fx engine. Everything is driven directly each frame
//! from a frame counter, as the original did; no scenes or paths. To keep a
//! fullscreen canvas cheap:
//!   * a cell can only ever belong to the few sites whose resting places are
//!     within its nearest one's distance plus twice the drift, so each cell
//!     keeps that short candidate list instead of searching every site;
//!   * every cell's look is reduced to a small key of quantized levels and
//!     its visual is only made again when the key changes;
//!   * the shards' text targets are found per text row by binary search,
//!     not by scanning every text character for every cell.
//!
//! Layers: text spaces 0 (the glass shows through gaps between letters),
//! glass 2, flying shards 3, text 6, seeds 7.

use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};

use clap::Args;

use crate::cli::parse_color;
use crate::effects::common::{parse_gradient_direction, parse_gradient_steps, parse_positive_int};
use crate::engine::animation::ExistingColorHandling;
use crate::engine::error::EngineError;
use crate::engine::terminal::{CharacterFilter, CharacterSort};
use crate::fx::run::Effect;
use crate::fx::visual::{VisualInfo, BOLD, HAS_COLORS};
use crate::fx::{Engine, Hooks, Sym, Visual, NONE};
use crate::utils::geometry::Coord;
use crate::utils::graphics::{Color, Gradient, GradientDirection};

#[derive(Args, Debug, Clone)]
pub struct VoronoiConfig {
    /// Number of sites seeded in the text. The canvas around the text gets
    /// sites of its own at a similar, slightly wider spacing.
    #[arg(long = "site-count", default_value_t = 18, value_parser = parse_positive_int)]
    pub site_count: i64,

    /// Maximum horizontal and vertical drift of each site, in cells.
    #[arg(long = "site-drift", default_value_t = 4, value_parser = parse_positive_int)]
    pub site_drift: i64,

    /// Frames over which the glass grows outward from the sites.
    #[arg(long = "growth-duration", default_value_t = 300, value_parser = parse_positive_int)]
    pub growth_duration: i64,

    /// Frames the completed living mosaic spends breathing and reshaping.
    #[arg(long = "living-duration", default_value_t = 420, value_parser = parse_positive_int)]
    pub living_duration: i64,

    /// Frames the window takes to shatter, stream into the text and anneal.
    #[arg(long = "shatter-duration", default_value_t = 420, value_parser = parse_positive_int)]
    pub shatter_duration: i64,

    /// Frames to admire the final lettering after the glass clears.
    #[arg(long = "final-hold-time", default_value_t = 270, value_parser = parse_positive_int)]
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

const LAYER_SPACE: i32 = 0;
const LAYER_GLASS: i32 = 2;
const LAYER_SHARD: i32 = 3;
const LAYER_TEXT: i32 = 6;
const LAYER_SEED: i32 = 7;

/// Every glass symbol, indexed by the S_* constants.
const SYMBOLS: [&str; 12] = [" ", "·", "✧", "✦", "─", "│", "╱", "╲", "◆", "◇", "◈", "•"];
const S_BLANK: usize = 0;
const S_DOT: usize = 1;
const S_TWINKLE: usize = 2;
const S_SPARK: usize = 3;
const S_HORIZONTAL: usize = 4;
const S_VERTICAL: usize = 5;
const S_UP: usize = 6;
const S_DOWN: usize = 7;
const S_SOLID: usize = 8;
const S_HOLLOW: usize = 9;
const S_JEWEL: usize = 10;
const S_BULLET: usize = 11;

/// Rows are squashed: terminal cells are about twice as tall as wide.
const ROW_SCALE: f64 = 1.75;
/// Width of the glowing crystallization front, in growth progress.
const FRONT: f64 = 0.03;
/// Shatter progress over which a pane's seams crack before it breaks.
const CRACK: f64 = 0.05;
/// The final glint sweeps across the text over this part of the shatter.
const ANNEAL_START: f64 = 0.70;
const ANNEAL_SPREAD: f64 = 0.24;
const ANNEAL_LENGTH: f64 = 0.06;
/// Frames a letter flashes after a shard lands in it.
const FLASH: i64 = 6;

// What a cell or letter shows; the low byte of its key.
const K_HIDDEN: u64 = 1;
const K_FRONT: u64 = 2;
const K_PANE: u64 = 3;
const K_SEAM: u64 = 4;
const K_SHARD: u64 = 5;
const K_DIM: u64 = 6;
const K_GLINT: u64 = 7;
const K_ETCHED: u64 = 8;
const K_LIT: u64 = 9;
const K_ANNEAL: u64 = 10;
const K_SETTLED: u64 = 11;
const K_FLOURISH_PANE: u64 = 12;
const K_FLOURISH_SEAM: u64 = 13;
const K_FLOURISH_TEXT: u64 = 14;
/// Growth progress a seed shows for.
const SEED_LIFE: f64 = 0.08;
// A seed's look.
const SEED_NEW: u64 = 100;
const SEED_SPARK: u64 = 101;
const SEED_TWINKLE: u64 = 102;
/// A key no cell has yet: forces the first visual.
const K_UNSET: u64 = u64::MAX;

fn key(kind: u64, sym: usize, color: usize, a: u64, b: u64, c: u64) -> u64 {
    kind | (sym as u64) << 8 | (color as u64 & 0xffff) << 16 | a << 32 | b << 40 | c << 48
}

type Rgb = [u8; 3];

fn rgb_of(color: &Color) -> Rgb {
    let (r, g, b) = color.rgb_ints();
    [r, g, b]
}

fn mix(a: Rgb, b: Rgb, f: f64) -> Rgb {
    let f = f.clamp(0.0, 1.0);
    std::array::from_fn(|i| (a[i] as f64 + (b[i] as f64 - a[i] as f64) * f).round() as u8)
}

fn color(c: Rgb) -> Color {
    Color::from_rgb(c[0], c[1], c[2])
}

const BLACK: Rgb = [8, 8, 18];
const WHITE: Rgb = [255, 255, 255];
const SUN: Rgb = [255, 248, 224];

/// A small deterministic per-cell hash (texture, jitter).
fn hash(column: i64, row: i64) -> u32 {
    let h = (column as u64)
        .wrapping_mul(0x9e37_79b9)
        .wrapping_add((row as u64).wrapping_mul(0x85eb_ca6b));
    ((h ^ (h >> 15)).wrapping_mul(0x2c1b_3c6d) >> 7) as u32
}

/// The memo's hasher: its keys are already well spread words.
#[derive(Default)]
struct KeyHasher(u64);

impl Hasher for KeyHasher {
    fn finish(&self) -> u64 {
        self.0
    }
    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.0 = (self.0.rotate_left(5) ^ b as u64).wrapping_mul(0x517c_c1b7_2722_0a95);
        }
    }
    fn write_u64(&mut self, n: u64) {
        self.0 = (n ^ n >> 29).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        self.0 ^= self.0 >> 32;
    }
}

struct Site {
    slot: u32,
    base_x: f64,
    base_y: f64,
    amplitude_x: f64,
    amplitude_y: f64,
    phase_x: f64,
    phase_y: f64,
    breath_phase: f64,
    color_index: usize,
    /// Growth progress at which the seed appears.
    seed: f64,
    /// Shatter progress at which the pane breaks.
    breaks: f64,
    seed_key: u64,
}

struct Text {
    slot: u32,
    /// The glass cell under it (NONE: off the canvas).
    cell: u32,
    final_rgb: Rgb,
    /// Shatter progress at which the final glint reaches it.
    anneal_at: f64,
    /// Diagonal axis position for the final stained-glass sunbeam.
    flourish_u: f32,
    dim: Visual,
    glint: Visual,
    settled: Visual,
    /// Spaces and --existing-color-handling always characters keep their
    /// input appearance throughout.
    fixed: bool,
    /// The frame a shard last landed in it.
    hit: i64,
    key: u64,
}

/// A local stained-glass cell hugging the logo silhouette during the final
/// cathedral sunbeam flourish.
struct HaloCell {
    cell: u32,
    u: f32,
    falloff: f32,
    color_index: u16,
    seam: u8,
    key: u64,
}

pub struct Voronoi {
    config: VoronoiConfig,
    sites: Vec<Site>,
    text: Vec<Text>,
    glass: Vec<Rgb>,
    border: Rgb,
    // the glass: one cell per canvas cell, row-major from the bottom row
    width: usize,
    height: usize,
    cell_slot: Vec<u32>,
    cell_coord: Vec<Coord>,
    /// The non-space letter on the cell (NONE: none); its glass never shows.
    cell_text: Vec<u32>,
    cell_hash: Vec<u32>,
    /// Position across the canvas for the sweeping beam of light, 0..1.
    cell_across: Vec<f32>,
    growth_order: Vec<f32>,
    /// Sites that can own the cell: candidates[cand_start[i]..cand_start[i + 1]].
    cand_start: Vec<u32>,
    candidates: Vec<u32>,
    owners: Vec<u32>,
    distance2: Vec<f32>,
    cell_key: Vec<u64>,
    // the shatter
    target: Vec<Coord>,
    target_text: Vec<u32>,
    depart: Vec<f32>,
    travel: Vec<f32>,
    /// 0 intact, 1 flying, 2 landed.
    shard_state: Vec<u8>,
    positions: Vec<(f64, f64)>,
    breath: Vec<u64>,
    syms: [Sym; SYMBOLS.len()],
    /// Where the beam of light is, across the canvas (NaN: no beam).
    beam_center: f32,
    /// Glass visuals by key.
    memo: HashMap<u64, Visual, BuildHasherDefault<KeyHasher>>,
    frame: i64,
    growth_end: i64,
    shatter_start: i64,
    shatter_end: i64,
    end_frame: i64,
    glass_cleared: bool,
    text_center_x: f64,
    text_center_y: f64,
    text_width: f64,
    text_height: f64,
    has_letters: bool,
    halo: Vec<HaloCell>,
}

impl Voronoi {
    pub fn new(config: VoronoiConfig) -> Self {
        Voronoi {
            config,
            sites: Vec::new(),
            text: Vec::new(),
            glass: Vec::new(),
            border: WHITE,
            width: 0,
            height: 0,
            cell_slot: Vec::new(),
            cell_coord: Vec::new(),
            cell_text: Vec::new(),
            cell_hash: Vec::new(),
            cell_across: Vec::new(),
            growth_order: Vec::new(),
            cand_start: Vec::new(),
            candidates: Vec::new(),
            owners: Vec::new(),
            distance2: Vec::new(),
            cell_key: Vec::new(),
            target: Vec::new(),
            target_text: Vec::new(),
            depart: Vec::new(),
            travel: Vec::new(),
            shard_state: Vec::new(),
            positions: Vec::new(),
            breath: Vec::new(),
            syms: [Sym(0); SYMBOLS.len()],
            beam_center: f32::NAN,
            memo: HashMap::default(),
            frame: 0,
            growth_end: 0,
            shatter_start: 0,
            shatter_end: 0,
            end_frame: 0,
            glass_cleared: false,
            text_center_x: 0.0,
            text_center_y: 0.0,
            text_width: 1.0,
            text_height: 1.0,
            has_letters: false,
            halo: Vec::new(),
        }
    }

    /// The sites' positions; they drift until the glass shatters.
    fn move_sites(&mut self) {
        let t = self.frame.min(self.shatter_start) as f64;
        self.positions.clear();
        self.positions.extend(self.sites.iter().map(|s| {
            (
                s.base_x + (t * 0.020 + s.phase_x).sin() * s.amplitude_x,
                s.base_y + (t * 0.017 + s.phase_y).cos() * s.amplitude_y,
            )
        }));
    }

    /// Each cell's nearest site (among its candidates) and squared
    /// row-scaled distance to it.
    fn assign_owners(&mut self) {
        let positions = &self.positions;
        for (i, coord) in self.cell_coord.iter().enumerate() {
            let (x, y) = (coord.column as f64, coord.row as f64);
            let mut best = (0u32, f64::INFINITY);
            let range = self.cand_start[i] as usize..self.cand_start[i + 1] as usize;
            for &s in &self.candidates[range] {
                let (sx, sy) = positions[s as usize];
                let dx = x - sx;
                let dy = (y - sy) * ROW_SCALE;
                let d = dx * dx + dy * dy;
                if d < best.1 {
                    best = (s, d);
                }
            }
            self.owners[i] = best.0;
            self.distance2[i] = best.1 as f32;
        }
    }

    /// Each pane's breath, 0..=7.
    fn breathe(&mut self) {
        let t = self.frame as f64;
        self.breath.clear();
        let start = self.growth_end / 2;
        self.beam_center = if self.frame < start || self.frame >= self.shatter_start {
            f32::NAN
        } else {
            let t = (self.frame - start) as f64 / (self.shatter_start - start).max(1) as f64;
            (-0.2 + 1.4 * t) as f32
        };
        self.breath
            .extend(self.sites.iter().map(|s| (((t * 0.035 + s.breath_phase).sin() + 1.0) * 3.5).round() as u64));
    }

    fn growth_progress(&self) -> f64 {
        (self.frame as f64 / self.config.growth_duration as f64).clamp(0.0, 1.0)
    }

    /// Shatter progress, 0..1, or -1 before the shatter.
    fn shatter_progress(&self) -> f64 {
        if self.frame < self.shatter_start {
            return -1.0;
        }
        ((self.frame - self.shatter_start) as f64 / self.config.shatter_duration as f64).clamp(0.0, 1.0)
    }

    /// The beam of light on a cell, 0..=7: it sweeps once across the window
    /// from halfway through the growth until the shatter.
    fn beam(&self, cell: usize) -> u64 {
        if self.beam_center.is_nan() {
            return 0;
        }
        let d = (self.cell_across[cell] - self.beam_center).abs() * (1.0 / 0.12);
        if d >= 1.0 {
            0
        } else {
            ((1.0 - d * d) * 7.0).round() as u64
        }
    }

    /// The glow near a pane's site, 0..=7.
    fn glow(&self, cell: usize) -> u64 {
        ((1.0 - (self.distance2[cell] as f64).sqrt() / 7.0).clamp(0.0, 1.0) * 7.0).round() as u64
    }

    /// The seam on a cell: the boundary with its right or upper neighbor's
    /// pane (so seams are a single cell wide), drawn across the line between
    /// the two sites; a diamond where three panes meet.
    fn seam(&self, index: usize) -> Option<usize> {
        let owners = &self.owners;
        let owner = owners[index];
        let (column, row) = (index % self.width, index / self.width);
        let has_right = column + 1 < self.width;
        let has_up = row + 1 < self.height;
        let right = if has_right { owners[index + 1] } else { owner };
        let up = if has_up { owners[index + self.width] } else { owner };
        if right == owner && up == owner {
            return None;
        }
        let diagonal = if has_right && has_up { owners[index + self.width + 1] } else { owner };
        let third = [right, up, diagonal].iter().any(|&o| o != owner && o != right && o != up)
            || (right != owner && up != owner && right != up);
        if third {
            return Some(S_SOLID);
        }
        let other = if right != owner { right } else { up };
        let (ox, oy) = self.positions[owner as usize];
        let (px, py) = self.positions[other as usize];
        let (dx, dy) = (-(py - oy) * ROW_SCALE, px - ox);
        let angle = dy.abs().atan2(dx.abs()).to_degrees();
        Some(if angle < 30.0 {
            S_HORIZONTAL
        } else if angle > 70.0 {
            S_VERTICAL
        } else if dx * dy > 0.0 {
            S_UP
        } else {
            S_DOWN
        })
    }

    fn pane_background(base: Rgb, breath: u64, glow: u64, beam: u64) -> Rgb {
        let light = 0.12 * breath as f64 / 7.0 + 0.16 * glow as f64 / 7.0 + 0.26 * beam as f64 / 7.0;
        mix(base, BLACK, 0.80 - light)
    }

    fn glass_visual(&self, e: &mut Engine, k: u64) -> Visual {
        let (kind, sym) = (k & 0xff, (k >> 8 & 0xff) as usize);
        let base = self.glass[(k >> 16 & 0xffff) as usize];
        let (a, b, c) = (k >> 32 & 0xff, k >> 40 & 0xff, k >> 48 & 0xff);
        let sym = self.syms[sym];
        match kind {
            K_FRONT => make(e, sym, Some(mix(base, WHITE, 0.6)), None, true),
            K_PANE => {
                // a blank cell shows only its background
                let fg = (sym != self.syms[S_BLANK]).then(|| mix(base, WHITE, 0.25 + 0.45 * c as f64 / 7.0));
                make(e, sym, fg, Some(Self::pane_background(base, a, b, c)), false)
            }
            K_SEAM => {
                let lead = mix(self.border, base, 0.45 - 0.25 * a as f64 / 7.0);
                make(e, sym, Some(mix(lead, WHITE, b as f64 / 7.0)), None, true)
            }
            K_FLOURISH_PANE => {
                let f = a as f64 / 12.0;
                let tint = mix(base, SUN, 0.18 * f);
                let bg = mix(BLACK, tint, 0.54 * f);
                make(e, sym, None, Some(bg), false)
            }
            K_FLOURISH_SEAM => {
                let f = a as f64 / 12.0;
                let lead = mix(self.border, SUN, 0.35);
                let fg = mix(BLACK, lead, 0.32 + 0.68 * f);
                let bg = mix(BLACK, base, 0.38 * f);
                make(e, sym, Some(fg), Some(bg), true)
            }
            _ => make(e, sym, Some(mix(base, WHITE, 0.2 + 0.6 * a as f64 / 15.0)), None, true),
        }
    }

    fn text_visual(&self, e: &mut Engine, t: &Text, k: u64) -> Visual {
        let kind = k & 0xff;
        let base = self.glass[(k >> 16 & 0xffff) as usize];
        let (a, b, c) = (k >> 32 & 0xff, k >> 40 & 0xff, k >> 48 & 0xff);
        let lit = mix(base, WHITE, 0.3);
        match kind {
            K_DIM => t.dim,
            K_GLINT => t.glint,
            K_SETTLED => t.settled,
            K_ETCHED => {
                let fg = mix(base, WHITE, 0.45 + 0.2 * a as f64 / 7.0 + 0.3 * c as f64 / 7.0);
                let bg = Self::pane_background(base, a, b, c);
                make(e, e.input_sym(t.slot), Some(fg), Some(bg), true)
            }
            K_LIT => make(e, e.input_sym(t.slot), Some(lit), None, true),
            K_FLOURISH_TEXT => {
                let f = a as f64 / 15.0;
                let jewel = mix(t.final_rgb, base, 0.52 * f);
                let fg = mix(jewel, SUN, 0.50 * f * f);
                let glow = mix(base, SUN, 0.22 * f);
                let bg = mix(BLACK, glow, 0.58 * f);
                make(e, e.input_sym(t.slot), Some(fg), Some(bg), true)
            }
            _ => make(e, e.input_sym(t.slot), Some(mix(lit, t.final_rgb, a as f64 / 15.0)), None, true),
        }
    }

    /// When the window starts to break: each cell's departure and flight.
    fn prepare_shatter(&mut self) {
        let mut longest = 1.0_f64;
        let distances: Vec<f64> = (0..self.cell_coord.len())
            .map(|i| {
                let (from, to) = (self.cell_coord[i], self.target[i]);
                let dx = (to.column - from.column) as f64;
                let dy = (to.row - from.row) as f64 * ROW_SCALE;
                let d = (dx * dx + dy * dy).sqrt();
                longest = longest.max(d);
                d
            })
            .collect();
        for (i, d) in distances.into_iter().enumerate() {
            let pane = &self.sites[self.owners[i] as usize];
            let jitter = (self.cell_hash[i] % 1000) as f64 / 1000.0;
            self.depart[i] = (pane.breaks + 0.05 * jitter) as f32;
            self.travel[i] = (0.08 + 0.22 * d / longest) as f32;
        }
    }

    fn update_glass(&mut self, e: &mut Engine) {
        let gp = self.growth_progress();
        let sp = self.shatter_progress();
        let twinkle_shift = (self.frame / 20) as u32;
        for i in 0..self.cell_slot.len() {
            if self.cell_text[i] != NONE || self.shard_state[i] == 2 {
                continue;
            }
            let slot = self.cell_slot[i];
            let order = self.growth_order[i] as f64;
            let owner = self.owners[i] as usize;
            let color = self.sites[owner].color_index;
            let h = self.cell_hash[i];
            let k = if gp < order {
                key(K_HIDDEN, 0, 0, 0, 0, 0)
            } else if sp >= self.depart[i] as f64 {
                let l = (sp - self.depart[i] as f64) / self.travel[i] as f64;
                if l >= 1.0 {
                    if self.shard_state[i] != 2 {
                        self.shard_state[i] = 2;
                        let t = self.target_text[i];
                        // only a shard that flew lands in a letter
                        if t != NONE && h % 5 < 3 {
                            self.text[t as usize].hit = self.frame;
                        }
                    }
                    key(K_HIDDEN, 0, 0, 0, 0, 0)
                } else {
                    if self.shard_state[i] == 0 {
                        self.shard_state[i] = 1;
                        e.set_layer(slot, LAYER_SHARD);
                    }
                    if h % 5 >= 3 {
                        // dust: a splinter too small to fly glints and is gone
                        if l < 0.3 {
                            key(K_SHARD, S_DOT, color, 0, 0, 0)
                        } else {
                            key(K_HIDDEN, 0, 0, 0, 0, 0)
                        }
                    } else {
                        // drawn in, faster and faster, each on its own curve
                        let eased = l * l;
                        let (from, to) = (self.cell_coord[i], self.target[i]);
                        let (dx, dy) = ((to.column - from.column) as f64, (to.row - from.row) as f64 * ROW_SCALE);
                        let length = (dx * dx + dy * dy).sqrt().max(1.0);
                        let swing = ((h >> 8) % 9) as f64 - 4.0;
                        let bow = (std::f64::consts::PI * l).sin() * swing.clamp(-length / 3.0, length / 3.0);
                        let (bx, by) = (-dy / length * bow, dx / length * bow / ROW_SCALE);
                        e.set_coordinate(
                            slot,
                            Coord::new(
                                (from.column as f64 + dx * eased + bx).round() as i64,
                                (from.row as f64 + (to.row - from.row) as f64 * eased + by).round() as i64,
                            ),
                        );
                            let sym = if l < 0.45 {
                            [S_SOLID, S_HOLLOW, S_JEWEL][(h % 3) as usize]
                        } else if l < 0.8 {
                            S_BULLET
                        } else {
                            S_DOT
                        };
                        key(K_SHARD, sym, color, (l * 15.0) as u64, 0, 0)
                    }
                }
            } else if gp - order < FRONT && self.frame < self.growth_end {
                key(K_FRONT, [S_SPARK, S_TWINKLE, S_DOT][(h % 3) as usize], color, 0, 0, 0)
            } else {
                let breath = self.breath[owner];
                match self.seam(i) {
                    Some(sym) => {
                        let crack = if sp >= 0.0 {
                            let start = self.sites[owner].breaks - CRACK;
                            ((sp - start) / CRACK).clamp(0.0, 1.0) * 7.0
                        } else {
                            0.0
                        };
                        key(K_SEAM, sym, color, breath, crack.round() as u64, 0)
                    }
                    None => {
                        let sym = if (h / 7 + twinkle_shift).is_multiple_of(53) {
                            S_TWINKLE
                        } else if h.is_multiple_of(9) {
                            S_DOT
                        } else {
                            S_BLANK
                        };
                        key(K_PANE, sym, color, breath, self.glow(i), self.beam(i))
                    }
                }
            };
            if k != self.cell_key[i] {
                self.cell_key[i] = k;
                if k & 0xff == K_HIDDEN {
                    e.set_visible(slot, false);
                } else {
                    let v = match self.memo.get(&k) {
                        Some(&v) => v,
                        None => {
                            let v = self.glass_visual(e, k);
                            self.memo.insert(k, v);
                            v
                        }
                    };
                    e.set_visual(slot, v);
                    e.set_visible(slot, true);
                }
            }
        }
    }

    fn update_text(&mut self, e: &mut Engine) {
        let gp = self.growth_progress();
        let sp = self.shatter_progress();
        for ti in 0..self.text.len() {
            let t = &self.text[ti];
            if t.fixed {
                continue;
            }
            let cell = t.cell as usize;
            let (owner, covered) = if t.cell != NONE {
                (self.owners[cell] as usize, gp >= self.growth_order[cell] as f64)
            } else {
                (t.slot as usize % self.sites.len(), false)
            };
            let color = self.sites[owner].color_index;
            let etched = || key(K_ETCHED, 0, color, self.breath[owner], self.glow(cell), self.beam(cell));
            let k = if sp < 0.0 {
                if !covered {
                    let glint = (self.frame + t.slot as i64 * 7) % 47 < 2;
                    key(if glint { K_GLINT } else { K_DIM }, 0, 0, 0, 0, 0)
                } else {
                    etched()
                }
            } else {
                let anneal = (sp - t.anneal_at) / ANNEAL_LENGTH;
                if anneal >= 1.0 {
                    key(K_SETTLED, 0, 0, 0, 0, 0)
                } else if anneal >= 0.25 {
                    key(K_ANNEAL, 0, color, ((anneal - 0.25) / 0.75 * 15.0) as u64, 0, 0)
                } else if anneal >= 0.0 || self.frame - t.hit < FLASH {
                    key(K_GLINT, 0, 0, 0, 0, 0)
                } else if covered && sp < self.sites[owner].breaks {
                    etched()
                } else {
                    key(K_LIT, 0, color, 0, 0, 0)
                }
            };
            if k != t.key {
                let v = self.text_visual(e, t, k);
                let slot = t.slot;
                self.text[ti].key = k;
                e.set_visual(slot, v);
                e.set_visible(slot, true);
            }
        }
    }

    /// The seeds spark where the glass starts to grow, until it has grown.
    fn update_seeds(&mut self, e: &mut Engine) {
        let gp = self.growth_progress();
        for index in 0..self.sites.len() {
            let site = &self.sites[index];
            // a seed sparks as its pane is born, then the glass covers it
            let visible = self.frame < self.growth_end && gp >= site.seed && gp < site.seed + SEED_LIFE;
            if !visible {
                if site.seed_key != K_HIDDEN {
                    e.set_visible(site.slot, false);
                    self.sites[index].seed_key = K_HIDDEN;
                }
                continue;
            }
            let (x, y) = self.positions[index];
            e.set_coordinate(site.slot, Coord::new(x.round() as i64, y.round() as i64));
            let age = (gp - site.seed) * self.config.growth_duration as f64;
            let k = if age < 8.0 {
                SEED_NEW
            } else if (self.frame + index as i64 * 5) % 24 < 12 {
                SEED_SPARK
            } else {
                SEED_TWINKLE
            };
            if k != site.seed_key {
                let base = self.glass[site.color_index];
                let v = match k {
                    SEED_NEW => make(e, self.syms[S_SPARK], Some(WHITE), None, true),
                    SEED_SPARK => make(e, self.syms[S_SPARK], Some(mix(base, WHITE, 0.55)), None, true),
                    _ => make(e, self.syms[S_TWINKLE], Some(mix(base, WHITE, 0.55)), None, true),
                };
                let slot = site.slot;
                self.sites[index].seed_key = k;
                e.set_visual(slot, v);
                e.set_visible(slot, true);
            }
        }
    }

    fn prepare_halo(&mut self, e: &mut Engine) {
        self.halo.clear();
        if !self.has_letters {
            return;
        }
        let halo_radius = (self.width as f64 * 0.065).clamp(5.5, 11.5);
        let span_x = self.text_width.max(halo_radius * 2.0);
        let span_y = self.text_height.max(halo_radius * 2.0 / ROW_SCALE);
        for i in 0..self.cell_slot.len() {
            if self.cell_text[i] != NONE {
                continue;
            }
            let coord = self.cell_coord[i];
            let target = self.target[i];
            let dx = (coord.column - target.column) as f64;
            let dy = (coord.row - target.row) as f64 * ROW_SCALE;
            let dist = (dx * dx + dy * dy).sqrt();
            if dist > halo_radius {
                continue;
            }
            let falloff = (1.0 - dist / halo_radius).clamp(0.0, 1.0);
            let across = 0.5 + (coord.column as f64 - self.text_center_x) / span_x;
            let down = 0.5 + (self.text_center_y - coord.row as f64) / span_y;
            let u = (0.78 * across + 0.22 * down) as f32;
            let owner = self.owners[i] as usize;
            let color_index = self.sites[owner].color_index as u16;
            let seam = self.seam(i).map_or(0xff, |s| s as u8);
            let slot = self.cell_slot[i];
            e.set_coordinate(slot, coord);
            e.set_layer(slot, LAYER_GLASS);
            self.halo.push(HaloCell {
                cell: i as u32,
                u,
                falloff: falloff.powf(1.4) as f32,
                color_index,
                seam,
                key: K_HIDDEN,
            });
        }
    }

    fn update_final(&mut self, e: &mut Engine) {
        if !self.glass_cleared {
            for &slot in &self.cell_slot {
                e.set_visible(slot, false);
            }
            for site in &self.sites {
                e.set_visible(site.slot, false);
            }
            self.prepare_halo(e);
            self.glass_cleared = true;
        }
        let last = self.frame >= self.end_frame;
        let hold_len = (self.end_frame - self.shatter_end).max(1) as f64;
        let p = ((self.frame - self.shatter_end) as f64 / hold_len).clamp(0.0, 1.0);

        // Cathedral sunbeam glides across the logo during 0.06..0.84 of the hold,
        // leaving a calm landing beat on the clean final lettering.
        let (beam_pos, env) = if last || !(0.06..0.84).contains(&p) {
            (0.0, 0.0)
        } else {
            let s = (p - 0.06) / 0.78;
            let smooth = s * s * (3.0 - 2.0 * s);
            let eased = 0.30 * s + 0.70 * smooth;
            let fade_in = (s / 0.10).clamp(0.0, 1.0);
            let fade_out = ((1.0 - s) / 0.12).clamp(0.0, 1.0);
            (-0.28 + 1.56 * eased, fade_in.min(fade_out))
        };

        let bell = |u: f64, half_width: f64| -> f64 {
            if env <= 0.0 {
                return 0.0;
            }
            let d = (u - beam_pos).abs() / half_width;
            if d >= 1.0 {
                0.0
            } else {
                let q = 1.0 - d * d;
                q * q * env
            }
        };

        // Ghostly backlit Voronoi panes & leaded seams right around the logo.
        for hi in 0..self.halo.len() {
            let h = &self.halo[hi];
            let slot = self.cell_slot[h.cell as usize];
            let intensity = bell(h.u as f64, 0.26) * h.falloff as f64;
            let level = if last { 0 } else { (intensity * 12.0).round() as u64 };
            let k = if level == 0 {
                K_HIDDEN
            } else if h.seam != 0xff {
                key(K_FLOURISH_SEAM, h.seam as usize, h.color_index as usize, level, 0, 0)
            } else {
                key(K_FLOURISH_PANE, S_BLANK, h.color_index as usize, level, 0, 0)
            };
            if k != h.key {
                self.halo[hi].key = k;
                if k == K_HIDDEN {
                    e.set_visible(slot, false);
                } else {
                    let v = match self.memo.get(&k) {
                        Some(&v) => v,
                        None => {
                            let v = self.glass_visual(e, k);
                            self.memo.insert(k, v);
                            v
                        }
                    };
                    e.set_visual(slot, v);
                    e.set_visible(slot, true);
                }
            }
        }

        // Each letter glows like backlit stained glass in its pane's jewel hue.
        for ti in 0..self.text.len() {
            let t = &self.text[ti];
            if t.fixed {
                continue;
            }
            let level = if last { 0 } else { (bell(t.flourish_u as f64, 0.22) * 15.0).round() as u64 };
            let k = if level == 0 {
                key(K_SETTLED, 0, 0, 0, 0, 0)
            } else {
                let owner = if t.cell != NONE {
                    self.owners[t.cell as usize] as usize
                } else {
                    t.slot as usize % self.sites.len()
                };
                let color = self.sites[owner].color_index;
                key(K_FLOURISH_TEXT, 0, color, level, 0, 0)
            };
            if k != t.key {
                let v = self.text_visual(e, t, k);
                let slot = t.slot;
                self.text[ti].key = k;
                e.set_visual(slot, v);
                e.set_visible(slot, true);
            }
        }
    }
}

impl Hooks for Voronoi {}

fn make(e: &mut Engine, sym: Sym, fg: Option<Rgb>, bg: Option<Rgb>, bold: bool) -> Visual {
    let attrs = HAS_COLORS | if bold { BOLD } else { 0 };
    let info = VisualInfo { sym, fg: fg.map(color), bg: bg.map(color), attrs };
    e.visuals.make(&e.symbols, info)
}

fn make_input(e: &mut Engine, sym: Sym, fg: Option<Color>, bg: Option<Color>, bold: bool) -> Visual {
    let attrs = HAS_COLORS | if bold { BOLD } else { 0 };
    e.visuals.make(&e.symbols, VisualInfo { sym, fg, bg, attrs })
}

/// The text cell nearest `coord` (cost dx² + 3dy², the first in reading
/// order on ties). `rows` holds each text row's sorted columns, top row first.
fn nearest_text(rows: &[(i64, Vec<i64>)], coord: Coord) -> Option<Coord> {
    let mut best: Option<(i64, i64, i64)> = None; // (cost, -row, column)
    for (row, columns) in rows {
        let dy = row - coord.row;
        let row_cost = 3 * dy * dy;
        if best.is_some_and(|b| row_cost > b.0) {
            continue;
        }
        let p = columns.partition_point(|&c| c < coord.column);
        for &column in columns[p.saturating_sub(1)..(p + 1).min(columns.len())].iter() {
            let dx = column - coord.column;
            let key = (dx * dx + row_cost, -row, column);
            if best.is_none_or(|b| key < b) {
                best = Some(key);
            }
        }
    }
    best.map(|(_, row, column)| Coord::new(column, -row))
}

fn scaled_distance2(a: (f64, f64), b: (f64, f64)) -> f64 {
    let dx = a.0 - b.0;
    let dy = (a.1 - b.1) * ROW_SCALE;
    dx * dx + dy * dy
}

impl Effect for Voronoi {
    fn build(&mut self, e: &mut Engine) -> Result<(), EngineError> {
        let config = self.config.clone();
        let handling = e.existing_color_handling();
        let canvas = e.canvas.clone();
        let (left, right, bottom, top) = (canvas.left, canvas.right, canvas.bottom, canvas.top);
        self.width = (right - left + 1).max(1) as usize;
        self.height = (top - bottom + 1).max(1) as usize;
        let (width, height) = (self.width, self.height);
        let cells = width * height;
        self.syms = SYMBOLS.map(|s| e.sym(s));
        self.glass = config.glass_colors.iter().map(rgb_of).collect();
        self.border = rgb_of(&config.border_color);

        // the text
        let gradient = Gradient::new(&config.final_gradient_stops, &config.final_gradient_steps, false, false)
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
        let text_width = (canvas.text_right - canvas.text_left).max(1) as f64;
        let text_height = (canvas.text_top - canvas.text_bottom).max(1) as f64;
        self.text_center_x = (canvas.text_left + canvas.text_right) as f64 * 0.5;
        self.text_center_y = (canvas.text_bottom + canvas.text_top) as f64 * 0.5;
        self.text_width = text_width;
        self.text_height = text_height;
        let halo_radius = (width as f64 * 0.065).clamp(5.5, 11.5);
        let flourish_span_x = text_width.max(halo_radius * 2.0);
        let flourish_span_y = text_height.max(halo_radius * 2.0 / ROW_SCALE);
        let in_canvas = |c: Coord| c.column >= left && c.column <= right && c.row >= bottom && c.row <= top;
        let cell_of = |c: Coord| (c.row - bottom) as usize * width + (c.column - left) as usize;
        let mut text_grid = vec![NONE; cells];
        let characters = e.get_characters(CharacterFilter::default(), CharacterSort::TopToBottomLeftToRight);
        let mut text_rows: Vec<(i64, Vec<i64>)> = Vec::new();
        for &slot in &characters {
            let coord = e.input_coord(slot);
            let sym = e.input_sym(slot);
            let space = e.symbol(sym) == " ";
            let gradient_color = mapping.get(&coord).copied().unwrap_or(config.final_gradient_stops[0]);
            let keep_input = handling == ExistingColorHandling::Always && e.uses_preexisting_colors(slot);
            let input = make_input(e, sym, e.input_fg(slot), e.input_bg(slot), e.input_bold(slot));
            let (final_color, settled) = match handling {
                _ if keep_input => (gradient_color, input),
                ExistingColorHandling::Dynamic => (e.input_fg(slot).unwrap_or(gradient_color), input),
                _ => (gradient_color, make_input(e, sym, Some(gradient_color), None, true)),
            };
            let final_rgb = rgb_of(&final_color);
            let fixed = space || keep_input;
            let dim = if fixed { settled } else { make(e, sym, Some(mix(final_rgb, BLACK, 0.62)), None, false) };
            let glint = make(e, sym, Some(WHITE), None, true);
            // the final glint sweeps from the top left to the bottom right
            let across = (coord.column - canvas.text_left) as f64 / text_width;
            let down = (canvas.text_top - coord.row) as f64 / text_height;
            let jitter = (slot.wrapping_mul(97) % 100) as f64 / 5000.0;
            e.set_layer(slot, if space { LAYER_SPACE } else { LAYER_TEXT });
            e.set_visual(slot, dim);
            e.set_visible(slot, true);
            let index = self.text.len() as u32;
            let cell = if !space && in_canvas(coord) {
                text_grid[cell_of(coord)] = index;
                cell_of(coord) as u32
            } else {
                NONE
            };
            let f_across = 0.5 + (coord.column as f64 - self.text_center_x) / flourish_span_x;
            let f_down = 0.5 + (self.text_center_y - coord.row as f64) / flourish_span_y;
            self.text.push(Text {
                slot,
                cell,
                final_rgb,
                anneal_at: ANNEAL_START + ANNEAL_SPREAD * (0.8 * across + 0.2 * down).clamp(0.0, 1.0) - jitter,
                flourish_u: (0.78 * f_across + 0.22 * f_down) as f32,
                dim,
                glint,
                settled,
                fixed,
                hit: i64::MIN / 2,
                key: K_UNSET,
            });
            if !space {
                match text_rows.last_mut() {
                    Some((row, columns)) if *row == coord.row => columns.push(coord.column),
                    _ => text_rows.push((coord.row, vec![coord.column])),
                }
            }
        }
        let letters: Vec<(f64, f64)> = text_rows
            .iter()
            .flat_map(|(row, columns)| columns.iter().map(move |&c| (c as f64, *row as f64)))
            .filter(|&(c, r)| in_canvas(Coord::new(c as i64, r as i64)))
            .collect();
        self.has_letters = !letters.is_empty();

        // the sites: spread evenly over the letters, then over the canvas
        // around them a little more widely
        let canvas_area = (width as f64) * (height as f64) * ROW_SCALE;
        let mut points: Vec<(f64, f64, bool)> = Vec::new();
        let text_sites = (config.site_count.max(1) as usize).min(letters.len()).min(cells);
        let spacing = if text_sites > 0 {
            let (mut c0, mut c1, mut r0, mut r1) = (f64::MAX, f64::MIN, f64::MAX, f64::MIN);
            for &(c, r) in &letters {
                (c0, c1, r0, r1) = (c0.min(c), c1.max(c), r0.min(r), r1.max(r));
            }
            let area = (c1 - c0 + 1.0) * (r1 - r0 + 1.0) * ROW_SCALE;
            // farthest-point sampling: every new site as far as possible
            // from the ones before it
            let mut nearest = vec![f64::INFINITY; letters.len()];
            let mut pick = e.rng.randint(0, letters.len() as i64 - 1) as usize;
            for _ in 0..text_sites {
                let (c, r) = letters[pick];
                points.push((c + e.rng.uniform(-0.4, 0.4), r + e.rng.uniform(-0.3, 0.3), true));
                let mut far = (0, -1.0);
                for (j, &p) in letters.iter().enumerate() {
                    nearest[j] = nearest[j].min(scaled_distance2(p, (c, r)));
                    if nearest[j] > far.1 {
                        far = (j, nearest[j]);
                    }
                }
                pick = far.0;
            }
            (area / text_sites as f64).sqrt()
        } else {
            (canvas_area / config.site_count.max(1) as f64).sqrt()
        };
        let outer = if text_sites > 0 {
            (spacing * 1.5).max((canvas_area / 400.0).sqrt()).max(6.0)
        } else {
            spacing.max((canvas_area / 400.0).sqrt()).max(1.0)
        };
        let (step_x, step_y) = (outer, outer / ROW_SCALE);
        let mut y = bottom as f64 + step_y * 0.5;
        while y <= top as f64 + 0.5 && points.len() < cells {
            let mut x = left as f64 + step_x * 0.5;
            while x <= right as f64 + 0.5 && points.len() < cells {
                let px = (x + e.rng.uniform(-0.35, 0.35) * step_x).clamp(left as f64, right as f64);
                let py = (y + e.rng.uniform(-0.35, 0.35) * step_y).clamp(bottom as f64, top as f64);
                let crowded = points
                    .iter()
                    .filter(|p| p.2)
                    .any(|&(sx, sy, _)| scaled_distance2((px, py), (sx, sy)) < (0.75 * outer).powi(2));
                if !crowded {
                    points.push((px, py, false));
                }
                x += step_x;
            }
            y += step_y;
        }
        if points.is_empty() {
            points.push(((left + right) as f64 / 2.0, (bottom + top) as f64 / 2.0, false));
        }

        // seeds spark in the letters first, then outward from them
        let center = if letters.is_empty() {
            ((left + right) as f64 / 2.0, (bottom + top) as f64 / 2.0)
        } else {
            let n = letters.len() as f64;
            (letters.iter().map(|p| p.0).sum::<f64>() / n, letters.iter().map(|p| p.1).sum::<f64>() / n)
        };
        let reach = points
            .iter()
            .map(|&(x, y, _)| scaled_distance2((x, y), center).sqrt())
            .fold(1.0_f64, f64::max);
        let drift = config.site_drift as f64;
        let spark = self.syms[S_SPARK];
        for &(base_x, base_y, in_text) in &points {
            let away = scaled_distance2((base_x, base_y), center).sqrt() / reach;
            let seed = if in_text || letters.is_empty() && away < 0.2 {
                0.05 + 0.10 * e.rng.random()
            } else {
                0.12 + 0.36 * away
            };
            let slot = e.add_character_sym(spark, Coord::new(base_x.round() as i64, base_y.round() as i64));
            e.set_layer(slot, LAYER_SEED);
            e.set_visible(slot, false);
            self.sites.push(Site {
                slot,
                base_x,
                base_y,
                amplitude_x: e.rng.uniform(0.6, drift.max(0.6)),
                amplitude_y: e.rng.uniform(0.4, (drift * 0.65).max(0.4)),
                phase_x: e.rng.uniform(0.0, std::f64::consts::TAU),
                phase_y: e.rng.uniform(0.0, std::f64::consts::TAU),
                breath_phase: e.rng.uniform(0.0, std::f64::consts::TAU),
                color_index: 0,
                seed,
                breaks: 0.0,
                seed_key: K_HIDDEN,
            });
        }
        // the window breaks from the outside in, pane by pane
        let mut by_distance: Vec<usize> = (0..self.sites.len()).collect();
        let away = |s: &Site| scaled_distance2((s.base_x, s.base_y), center);
        by_distance.sort_by(|&a, &b| away(&self.sites[b]).total_cmp(&away(&self.sites[a])).then(a.cmp(&b)));
        let last = (self.sites.len() - 1).max(1) as f64;
        for (rank, &s) in by_distance.iter().enumerate() {
            self.sites[s].breaks = CRACK + 0.01 + 0.40 * rank as f64 / last;
        }

        // the glass: a cell on every canvas cell
        let fallback = Coord::new((left + right) / 2, (bottom + top) / 2);
        let glass_sym = self.syms[S_BLANK];
        for row in 0..height {
            for column in 0..width {
                let coord = Coord::new(left + column as i64, bottom + row as i64);
                let slot = e.add_character_sym(glass_sym, coord);
                e.set_layer(slot, LAYER_GLASS);
                let target = nearest_text(&text_rows, coord).unwrap_or(fallback);
                self.cell_slot.push(slot);
                self.cell_coord.push(coord);
                self.cell_text.push(text_grid[row * width + column]);
                self.cell_hash.push(hash(coord.column, coord.row));
                self.cell_across.push(
                    (0.8 * column as f64 / width as f64 + 0.2 * row as f64 / height as f64) as f32,
                );
                self.target.push(target);
                self.target_text.push(if in_canvas(target) { text_grid[cell_of(target)] } else { NONE });
            }
        }

        // a cell can only belong to the sites whose resting places are
        // within its nearest one's distance plus twice the farthest drift
        let swing = (drift * drift + (drift * 0.65 * ROW_SCALE).powi(2)).sqrt();
        let mut distances = vec![0.0; self.sites.len()];
        self.cand_start.push(0);
        for coord in &self.cell_coord {
            let p = (coord.column as f64, coord.row as f64);
            let mut nearest = f64::INFINITY;
            for (s, site) in self.sites.iter().enumerate() {
                distances[s] = scaled_distance2(p, (site.base_x, site.base_y));
                nearest = nearest.min(distances[s]);
            }
            let limit = (nearest.sqrt() + 2.0 * swing + 1e-6).powi(2);
            self.candidates
                .extend(distances.iter().enumerate().filter(|(_, &d)| d <= limit).map(|(s, _)| s as u32));
            self.cand_start.push(self.candidates.len() as u32);
        }

        self.growth_end = config.growth_duration;
        self.shatter_start = config.growth_duration.saturating_add(config.living_duration);
        self.shatter_end = self.shatter_start.saturating_add(config.shatter_duration);
        self.end_frame = self.shatter_end.saturating_add(config.final_hold_time);
        self.frame = 0;
        self.owners = vec![0; cells];
        self.distance2 = vec![0.0; cells];
        self.move_sites();
        self.assign_owners();

        // neighboring panes get different colors where the palette allows
        let colors = self.glass.len();
        let mut neighbors: Vec<Vec<u32>> = vec![Vec::new(); self.sites.len()];
        for i in 0..cells {
            let o = self.owners[i];
            let (column, row) = (i % width, i / width);
            for j in [(column + 1 < width).then_some(i + 1), (row + 1 < height).then_some(i + width)]
                .into_iter()
                .flatten()
            {
                let p = self.owners[j];
                if p != o && !neighbors[o as usize].contains(&p) {
                    neighbors[o as usize].push(p);
                    neighbors[p as usize].push(o);
                }
            }
        }
        let mut assigned = vec![usize::MAX; self.sites.len()];
        for s in 0..self.sites.len() {
            let start = s * 3 % colors;
            let free = (0..colors)
                .map(|k| (start + k) % colors)
                .find(|&c| neighbors[s].iter().all(|&n| assigned[n as usize] != c));
            assigned[s] = free.unwrap_or(s % colors);
            self.sites[s].color_index = assigned[s];
        }

        // the glass grows from each seed at one speed, like crystal grains
        let mut speed = f64::INFINITY;
        for i in 0..cells {
            let d = (self.distance2[i] as f64).sqrt();
            if d > 0.0 {
                speed = speed.min((0.95 - self.sites[self.owners[i] as usize].seed) / d);
            }
        }
        if !speed.is_finite() {
            speed = 0.0;
        }
        self.growth_order = (0..cells)
            .map(|i| {
                let seed = self.sites[self.owners[i] as usize].seed;
                let jitter = (self.cell_hash[i] % 100) as f64 / 100.0 * 0.02;
                (seed + (self.distance2[i] as f64).sqrt() * speed + jitter).min(0.97) as f32
            })
            .collect();

        self.cell_key = vec![K_UNSET; cells];
        self.depart = vec![f32::INFINITY; cells];
        self.travel = vec![1.0; cells];
        self.shard_state = vec![0; cells];
        Ok(())
    }

    fn next_frame(&mut self, e: &mut Engine) -> bool {
        if self.frame > self.end_frame {
            return false;
        }
        // the grown window changes slowly: it is redrawn every other frame
        let resting = self.frame > self.growth_end && self.frame < self.shatter_start && self.frame % 2 == 1;
        if self.frame <= self.shatter_start {
            // the sites stop drifting when the glass shatters; they move
            // well under a cell a frame, so owners are found every other one
            self.move_sites();
            if self.frame % 2 == 0 || self.frame == self.shatter_start {
                self.assign_owners();
            }
        }
        if self.frame == self.shatter_start {
            self.prepare_shatter();
        }
        if resting {
            self.update_seeds(e);
        } else if self.frame < self.shatter_end {
            self.breathe();
            self.update_glass(e);
            self.update_text(e);
            self.update_seeds(e);
        } else {
            self.update_final(e);
        }
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

    #[derive(Parser)]
    struct Cli {
        #[command(flatten)]
        config: VoronoiConfig,
    }

    fn config(args: &[&str]) -> VoronoiConfig {
        let mut argv = vec!["voronoi"];
        argv.extend_from_slice(args);
        Cli::parse_from(argv).config
    }

    fn engine(input: &str, width: i64, height: i64, handling: ExistingColorHandling) -> Engine {
        let config = TerminalConfig {
            canvas_width: width,
            canvas_height: height,
            existing_color_handling: handling,
            ..TerminalConfig::default()
        };
        Engine::new(input, config, Rng::seeded(7), Clock::virtual_with_frame_rate(60)).unwrap()
    }

    fn run(effect: &mut Voronoi, e: &mut Engine) -> u64 {
        effect.build(e).unwrap();
        let mut frames = 0;
        while effect.next_frame(e) {
            e.render_here();
            frames += 1;
            assert!(frames < 100_000, "voronoi does not end");
        }
        frames
    }

    fn assert_settled(e: &Engine) {
        for &slot in &e.input_chars {
            assert!(e.is_visible(slot));
            assert_eq!(e.coord(slot), e.input_coord(slot));
            assert_eq!(e.visual_info(e.current_visual(slot)).sym, e.input_sym(slot));
        }
        for &slot in &e.added_chars {
            assert!(!e.is_visible(slot), "added character {slot} still visible");
        }
    }

    #[test]
    fn runs_to_completion_on_edge_inputs() {
        let long = "x".repeat(500);
        let cases: [(&str, i64, i64); 8] = [
            ("OMARCHY\nhello world\n", 80, 24),
            ("", 20, 5),
            ("A", 80, 24),
            ("A", 1, 1),
            (long.as_str(), 80, 24),
            ("OMARCHY\nhello world\n", 10, 3),
            ("OMARCHY\nhello world\n", 300, 90),
            ("wide 日本語 chars ✦\n", 40, 10),
        ];
        for (input, w, h) in cases {
            let mut e = engine(input, w, h, ExistingColorHandling::Ignore);
            let mut effect = Voronoi::new(config(&[]));
            assert_eq!(run(&mut effect, &mut e), 1411, "{input:?} {w}x{h}");
            assert_settled(&e);
        }
    }

    #[test]
    fn mostly_spaces_and_many_sites() {
        let mut e = engine("     \n  x  \n", 12, 4, ExistingColorHandling::Ignore);
        run(&mut Voronoi::new(config(&["--site-count", "1000"])), &mut e);
        assert_settled(&e);
    }

    #[test]
    fn timing_options_feed_the_run_length() {
        let frames = |args: &[&str]| {
            let mut e = engine("OMARCHY\n", 30, 8, ExistingColorHandling::Ignore);
            run(&mut Voronoi::new(config(args)), &mut e)
        };
        let base = frames(&[]);
        for option in ["--growth-duration", "--living-duration", "--shatter-duration", "--final-hold-time"] {
            let default = config(&[]);
            let value = match option {
                "--growth-duration" => default.growth_duration,
                "--living-duration" => default.living_duration,
                "--shatter-duration" => default.shatter_duration,
                _ => default.final_hold_time,
            };
            assert_eq!(frames(&[option, &(value + 7).to_string()]), base + 7, "{option}");
        }
        let short = ["--growth-duration", "1", "--living-duration", "1", "--shatter-duration", "1", "--final-hold-time", "1"];
        assert_eq!(frames(&short), 5);
    }

    #[test]
    fn dynamic_keeps_input_colors() {
        let input = "\x1b[38;2;255;0;0mred\x1b[0m plain\n";
        for handling in [ExistingColorHandling::Dynamic, ExistingColorHandling::Always] {
            let mut e = engine(input, 40, 10, handling);
            run(&mut Voronoi::new(config(&[])), &mut e);
            assert_settled(&e);
            for &slot in &e.input_chars {
                let info = e.visual_info(e.current_visual(slot));
                if e.input_fg(slot).is_some() {
                    assert_eq!(info.fg, e.input_fg(slot));
                } else if handling == ExistingColorHandling::Dynamic {
                    assert_eq!(info.fg, None);
                }
            }
        }
    }

    #[test]
    fn deterministic_for_a_seed() {
        let state = || {
            let mut e = engine("OMARCHY\nhello world\n", 40, 12, ExistingColorHandling::Ignore);
            let mut effect = Voronoi::new(config(&[]));
            effect.build(&mut e).unwrap();
            for _ in 0..1000 {
                effect.next_frame(&mut e);
                e.render_here();
            }
            (0..e.char_count() as u32)
                .map(|s| (e.coord(s), e.is_visible(s), e.current_visual(s).0))
                .collect::<Vec<_>>()
        };
        assert_eq!(state(), state());
    }

    #[test]
    fn nearest_text_prefers_reading_order() {
        let rows = vec![(5, vec![1, 5]), (3, vec![3])];
        assert_eq!(nearest_text(&rows, Coord::new(3, 5)), Some(Coord::new(1, 5)));
        assert_eq!(nearest_text(&rows, Coord::new(3, 3)), Some(Coord::new(3, 3)));
        assert_eq!(nearest_text(&[], Coord::new(3, 3)), None);
    }

    #[test]
    fn the_logo_reads_through_the_living_glass() {
        let input = "OMARCHY\nhello world\n";
        let mut e = engine(input, 60, 16, ExistingColorHandling::Ignore);
        let mut effect = Voronoi::new(config(&[]));
        effect.build(&mut e).unwrap();
        for _ in 0..(effect.config.growth_duration + effect.config.living_duration / 2) {
            effect.next_frame(&mut e);
            e.render_here();
        }
        let blank = e.sym(" ");
        let mut glass = 0;
        for &slot in &e.added_chars {
            glass += e.is_visible(slot) as usize;
        }
        assert!(glass > 60 * 16 / 2, "the window has grown over the canvas");
        for &slot in &e.input_chars {
            if e.input_sym(slot) == blank {
                continue;
            }
            assert!(e.is_visible(slot));
            let info = e.visual_info(e.current_visual(slot));
            assert_eq!(info.sym, e.input_sym(slot));
            assert!(info.bg.is_some(), "letters are etched in their pane");
        }
    }
}
