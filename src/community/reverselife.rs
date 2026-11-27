//! reverselife: the input glyphs seed Conway's Game of Life, which is run
//! forward; the generations then play backward from the most chaotic one
//! into the text, a white pulse marks the seed and the letters cool in.
//! Once the text settles, a handful of stray Conway gliders keep sailing
//! around the logo with faint ghost trails, bouncing off the letters and
//! making each touched letter flicker off and back on once before they
//! dissolve cleanly.
//!
//! So the chaos never dies out (a short word on a big screen would leave a
//! blank field), small Life sparks (R-pentomino, B- and Pi-heptomino) are
//! dropped across the canvas during the forward run, later the farther they
//! lie from the text. Played backward the whole screen of chaos draws in onto
//! the letters, and the first generations stay spark-free so the last moments
//! are the text's own Life running back into its silhouette, eased to slow
//! down as it lands.
//!
//! Original effect by Lukas Innig (@derluke), https://github.com/derluke/ttfx, MIT.
//! Rewritten for the fx engine.
//!
//! Everything is driven by a frame counter, no scenes or paths. Generations
//! are bit sets; once the field repeats an earlier generation the rest are
//! read from that cycle instead of being stored. Only cells that are ever
//! alive get a character. Between two generations the field is blended per
//! frame (cells being born brighten in, dying ones dim into a fading ghost,
//! colors drift continuously), so the playback runs smooth at any frame rate.

use std::collections::HashMap;

use clap::Args;

use crate::cli::parse_color;
use crate::effects::common::{
    parse_gradient_direction, parse_gradient_steps, parse_non_negative_int, parse_positive_int,
    parse_symbol,
};
use crate::engine::animation::ExistingColorHandling;
use crate::engine::error::EngineError;
use crate::engine::terminal::{CharacterFilter, CharacterSort};
use crate::fx::run::Effect;
use crate::fx::visual::{VisualInfo, BOLD, HAS_COLORS};
use crate::fx::{Engine, FxBuild, Hooks, Visual};
use crate::utils::geometry::Coord;
use crate::utils::graphics::{shift_color_towards, Color, Gradient, GradientDirection};

#[derive(Args, Debug, Clone)]
pub struct ReverselifeConfig {
    /// Number of Conway generations to simulate before playing them backward.
    #[arg(long = "simulation-steps", default_value_t = 60, value_parser = parse_positive_int)]
    pub simulation_steps: i64,

    /// Frames per generation, on average, while the generations play backward.
    #[arg(long = "generation-time", default_value_t = 8, value_parser = parse_positive_int)]
    pub generation_time: i64,

    /// Frames of chaos before the rewind starts (the field running into its most evolved generation).
    #[arg(long = "chaos-hold-time", default_value_t = 120, value_parser = parse_non_negative_int)]
    pub chaos_hold_time: i64,

    /// Frames used to exchange the final cell silhouette for the original glyphs.
    #[arg(long = "resolve-duration", default_value_t = 200, value_parser = parse_positive_int)]
    pub resolve_duration: i64,

    /// Frames to hold the readable final text.
    #[arg(long = "final-hold-time", default_value_t = 360, value_parser = parse_non_negative_int)]
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

/// Color fades are drawn in this many steps (bounds the visuals interned).
const LEVELS: usize = 32;
/// The backward playback runs generation = steps * (time left)^REWIND_EASE.
const REWIND_EASE: f64 = 1.6;
/// Generations a ghost trail of recently shown cells lingers.
const TRAIL: usize = 4;
/// Brightness steps a cell fades in or out with between two generations.
const FADE_LEVELS: usize = 16;
/// Hue steps between two neighbouring cell colors.
const HUES: usize = 8;
/// Brightness of a fresh ghost "·"; a fading cell turns into one below it.
const GHOST_MAX: f64 = 0.4;
/// Frames per Conway phase for the flourish gliders (4 phases = 1 diagonal cell).
const GLIDER_STEP_FRAMES: i64 = 2;
/// Duration of a single letter's impact flicker (flash -> off -> snap on -> cool).
const FLICKER_DURATION: i64 = 24;
/// Minimum frames before the same letter cluster can flicker again.
const FLICKER_COOLDOWN: i64 = 28;
/// Canonical 4-phase Conway's Game of Life glider moving in direction (+1, -1),
/// centered around (0, 0). Transform (ox, oy) -> (dx * ox, -dy * oy) for any
/// diagonal direction (dx, dy) in {-1, +1}^2.
const GLIDER_PHASES: [[(i64, i64); 5]; 4] = [
    [(0, 1), (1, 0), (-1, -1), (0, -1), (1, -1)],
    [(-1, 0), (1, 0), (0, -1), (1, -1), (0, -2)],
    [(1, 0), (-1, -1), (1, -1), (0, -2), (1, -2)],
    [(0, 0), (1, -1), (2, -1), (0, -2), (1, -2)],
];

/// The simulated generations as bit sets over the canvas, with the cycle the
/// field settled into (if it repeated before the last generation).
struct History {
    words: usize,
    stored: Vec<Vec<u64>>,
    /// (first generation of the cycle, period)
    cycle: Option<(usize, usize)>,
}

impl History {
    fn stored_index(&self, generation: usize) -> usize {
        match self.cycle {
            Some((start, period)) if generation >= self.stored.len() => {
                start + (generation - start) % period
            }
            _ => generation.min(self.stored.len() - 1),
        }
    }

    #[inline]
    fn alive(&self, generation: usize, cell: usize) -> bool {
        let bits = &self.stored[self.stored_index(generation)];
        bits[cell / 64] >> (cell % 64) & 1 != 0
    }
}

fn pack(cells: &[bool], words: usize) -> Vec<u64> {
    let mut bits = vec![0u64; words];
    for (i, _) in cells.iter().enumerate().filter(|(_, &a)| a) {
        bits[i / 64] |= 1 << (i % 64);
    }
    bits
}

/// One Conway step on a bounded (non-wrapping) field.
fn life_step(current: &[bool], next: &mut [bool], width: usize, height: usize) {
    for row in 0..height {
        for column in 0..width {
            let mut neighbors = 0;
            for other_row in row.saturating_sub(1)..=(row + 1).min(height - 1) {
                for other_column in column.saturating_sub(1)..=(column + 1).min(width - 1) {
                    if (other_row != row || other_column != column)
                        && current[other_row * width + other_column]
                    {
                        neighbors += 1;
                    }
                }
            }
            let index = row * width + column;
            next[index] = neighbors == 3 || (current[index] && neighbors == 2);
        }
    }
}

/// A spark dropped into the field after a generation: (generation, cells).
type Spark = (usize, Vec<usize>);

/// Simulate `steps` generations from `seed`, OR-ing each spark into the field
/// right after its generation is computed. Once the last spark is in, the
/// run stops early at a repeat.
fn simulate(
    seed: Vec<bool>,
    width: usize,
    height: usize,
    steps: usize,
    sparks: &[Spark],
) -> History {
    let words = seed.len().div_ceil(64).max(1);
    let quiet_after = sparks.iter().map(|&(g, _)| g).max().unwrap_or(0);
    let mut seen: HashMap<Vec<u64>, usize, FxBuild> = HashMap::default();
    let mut current = seed;
    let mut next = vec![false; current.len()];
    let first = pack(&current, words);
    if quiet_after == 0 {
        seen.insert(first.clone(), 0);
    }
    let mut stored = vec![first];
    let mut cycle = None;
    let mut spark = 0;
    for generation in 1..=steps {
        if width == 0 || height == 0 {
            cycle = Some((0, 1));
            break;
        }
        life_step(&current, &mut next, width, height);
        std::mem::swap(&mut current, &mut next);
        while spark < sparks.len() && sparks[spark].0 <= generation {
            for &cell in &sparks[spark].1 {
                current[cell] = true;
            }
            spark += 1;
        }
        let bits = pack(&current, words);
        if generation >= quiet_after {
            if let Some(&earlier) = seen.get(&bits) {
                cycle = Some((earlier, generation - earlier));
                break;
            }
            seen.insert(bits.clone(), generation);
        }
        stored.push(bits);
    }
    History {
        words,
        stored,
        cycle,
    }
}

/// Small Life patterns that burst into long-lived chaos: the R-pentomino,
/// the B-heptomino and the Pi-heptomino, as (row, column) offsets.
const SPARK_SHAPES: [&[(i64, i64)]; 3] = [
    &[(0, 1), (0, 2), (1, 0), (1, 1), (2, 1)],
    &[(0, 0), (0, 2), (0, 3), (1, 0), (1, 1), (1, 2), (2, 1)],
    &[(0, 0), (0, 1), (0, 2), (1, 0), (1, 2), (2, 0), (2, 2)],
];

/// Canvas cells per spark.
const SPARK_AREA: usize = 40;

/// Distance of every cell to the nearest seed cell (a chamfer transform,
/// rows counted twice as far as columns since a cell is about twice as tall
/// as it is wide); None when there is no seed cell.
fn seed_distance(seed: &[bool], width: usize, height: usize) -> Option<Vec<u32>> {
    if !seed.iter().any(|&a| a) {
        return None;
    }
    const FAR: u32 = u32::MAX / 4;
    let (h, v, d) = (2, 4, 5);
    let mut dist: Vec<u32> = seed.iter().map(|&a| if a { 0 } else { FAR }).collect();
    for row in 0..height {
        for column in 0..width {
            let i = row * width + column;
            let mut best = dist[i];
            if column > 0 {
                best = best.min(dist[i - 1] + h);
            }
            if row > 0 {
                best = best.min(dist[i - width] + v);
                if column > 0 {
                    best = best.min(dist[i - width - 1] + d);
                }
                if column + 1 < width {
                    best = best.min(dist[i - width + 1] + d);
                }
            }
            dist[i] = best;
        }
    }
    for row in (0..height).rev() {
        for column in (0..width).rev() {
            let i = row * width + column;
            let mut best = dist[i];
            if column + 1 < width {
                best = best.min(dist[i + 1] + h);
            }
            if row + 1 < height {
                best = best.min(dist[i + width] + v);
                if column + 1 < width {
                    best = best.min(dist[i + width + 1] + d);
                }
                if column > 0 {
                    best = best.min(dist[i + width - 1] + d);
                }
            }
            dist[i] = best;
        }
    }
    Some(dist)
}

/// Generation at which the seed alone has died out, if it does in `steps`.
fn dies_at(seed: &[bool], width: usize, height: usize, steps: usize) -> Option<usize> {
    let history = simulate(seed.to_vec(), width, height, steps, &[]);
    match history.cycle {
        Some((start, 1)) if history.stored[start].iter().all(|&w| w == 0) => Some(start),
        _ => None,
    }
}

/// Sparks scattered over the canvas, dropped in later the farther they lie
/// from the text: played backward, the chaos draws in onto the letters. The
/// first generations stay spark-free so the end of the playback is the text's
/// own Life running backward into its silhouette.
fn plan_sparks(
    e: &mut Engine,
    seed: &[bool],
    width: usize,
    height: usize,
    steps: usize,
) -> Vec<Spark> {
    let area = width * height;
    if area < 9 || steps < 2 {
        return Vec::new();
    }
    let Some(dist) = seed_distance(seed, width, height) else {
        return Vec::new();
    };
    let far = dist.iter().copied().max().unwrap_or(0).max(1) as f64;
    // a big text's own Life carries the landing; a small one barely lives,
    // so the sparks come in almost to the end
    let seed_cells = seed.iter().filter(|&&a| a).count();
    let quiet = (steps / 8)
        .min(seed_cells / 25)
        .max(2)
        .min(dies_at(seed, width, height, steps).unwrap_or(steps))
        .clamp(1, steps);
    let last = (steps * 3 / 4).max(quiet);
    let count = (area / SPARK_AREA).max(1);
    let mut sparks: Vec<Spark> = Vec::with_capacity(count);
    for _ in 0..count {
        let row = e.rng.randint(0, height as i64 - 1);
        let column = e.rng.randint(0, width as i64 - 1);
        let shape = SPARK_SHAPES[e.rng.randint(0, SPARK_SHAPES.len() as i64 - 1) as usize];
        let turn = e.rng.randint(0, 7);
        let jitter = e.rng.random();
        let reach = dist[row as usize * width + column as usize] as f64 / far;
        let at = (reach * 0.85 + jitter * 0.15).clamp(0.0, 1.0);
        // the rewind is eased, so this spreads the vanishing evenly in time
        let generation = quiet + ((last - quiet) as f64 * at.powf(REWIND_EASE)).round() as usize;
        let cells = shape
            .iter()
            .filter_map(|&(r, c)| {
                let (r, c) = if turn & 1 != 0 { (c, r) } else { (r, c) };
                let r = if turn & 2 != 0 { -r } else { r };
                let c = if turn & 4 != 0 { -c } else { c };
                let (r, c) = (row + r - 1, column + c - 1);
                ((0..height as i64).contains(&r) && (0..width as i64).contains(&c))
                    .then(|| r as usize * width + c as usize)
            })
            .collect();
        sparks.push((generation, cells));
    }
    sparks.sort_by_key(|&(g, _)| g);
    sparks
}

fn other(message: String) -> EngineError {
    EngineError::Other(message)
}

/// A visual in plain fg color (no attributes).
fn plain(e: &mut Engine, symbol: &str, fg: Color) -> Visual {
    let sym = e.sym(symbol);
    e.visuals.make(
        &e.symbols,
        VisualInfo {
            sym,
            fg: Some(fg),
            bg: None,
            attrs: HAS_COLORS,
        },
    )
}

/// An input character's visual in these colors, with Animation.set_appearance's
/// override: under --existing-color-handling always a character with input
/// colors keeps them.
fn text_visual(e: &mut Engine, slot: u32, fg: Option<Color>, bg: Option<Color>) -> Visual {
    let sym = e.input_sym(slot);
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
            attrs: HAS_COLORS,
        }
    };
    e.visuals.make(&e.symbols, info)
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Shown {
    Nothing,
    Field,
    Pulse(usize),
    Fade(usize),
    Final,
}

#[derive(Clone, Copy)]
struct Arena {
    left: i64,
    right: i64,
    bottom: i64,
    top: i64,
}

struct Glider {
    anchor_col: i64,
    anchor_row: i64,
    dx: i64,
    dy: i64,
    phase: usize,
    spawn_delay: i64,
    step_offset: i64,
    bounce_flash: i64,
    dissolve_start: i64,
    color_idx: usize,
    body_slots: [u32; 5],
    trail1_slots: [u32; 5],
    trail2_slots: [u32; 5],
    trail1_pos: [Option<(i64, i64)>; 5],
    trail2_pos: [Option<(i64, i64)>; 5],
}

#[derive(Clone, Copy)]
struct ClusterFlicker {
    start_frame: i64,
    impact_col: i64,
    impact_row: i64,
    max_delay: i64,
}

/// Cells of a glider at `(anchor_col, anchor_row)` with velocity `(dx, dy)` and `phase`.
fn glider_cells(
    anchor_col: i64,
    anchor_row: i64,
    dx: i64,
    dy: i64,
    phase: usize,
) -> [(i64, i64); 5] {
    let mut out = [(0, 0); 5];
    for (i, &(ox, oy)) in GLIDER_PHASES[phase % 4].iter().enumerate() {
        out[i] = (anchor_col + dx * ox, anchor_row - dy * oy);
    }
    out
}

/// Group occupied text cells into 8-connected letter clusters; split very wide
/// or tall blocks into local chunks so a single flicker stays localized.
fn build_letter_clusters(
    text_coords: &[(i64, i64)],
    text_grid: &[u32],
    width: usize,
    height: usize,
) -> (Vec<Vec<usize>>, Vec<usize>) {
    let n = text_coords.len();
    let mut cluster_of_text = vec![usize::MAX; n];
    let mut clusters: Vec<Vec<usize>> = Vec::new();
    let mut queue: Vec<usize> = Vec::new();

    for start in 0..n {
        if cluster_of_text[start] != usize::MAX {
            continue;
        }
        let (sc, sr) = text_coords[start];
        if !(0..width as i64).contains(&sc) || !(0..height as i64).contains(&sr) {
            let cid = clusters.len();
            cluster_of_text[start] = cid;
            clusters.push(vec![start]);
            continue;
        }
        queue.clear();
        queue.push(start);
        cluster_of_text[start] = 0; // temporary mark
        let mut comp = Vec::new();
        let mut head = 0;
        while head < queue.len() {
            let idx = queue[head];
            head += 1;
            comp.push(idx);
            let (c, r) = text_coords[idx];
            for dr in -1..=1 {
                let nr = r + dr;
                if !(0..height as i64).contains(&nr) {
                    continue;
                }
                for dc in -1..=1 {
                    if dc == 0 && dr == 0 {
                        continue;
                    }
                    let nc = c + dc;
                    if !(0..width as i64).contains(&nc) {
                        continue;
                    }
                    let nb = text_grid[nr as usize * width + nc as usize];
                    if nb != u32::MAX && cluster_of_text[nb as usize] == usize::MAX {
                        cluster_of_text[nb as usize] = 0;
                        queue.push(nb as usize);
                    }
                }
            }
        }
        let (mut min_c, mut max_c, mut min_r, mut max_r) = (i64::MAX, i64::MIN, i64::MAX, i64::MIN);
        for &idx in &comp {
            let (c, r) = text_coords[idx];
            min_c = min_c.min(c);
            max_c = max_c.max(c);
            min_r = min_r.min(r);
            max_r = max_r.max(r);
        }
        if max_c - min_c <= 18 && max_r - min_r <= 12 {
            let cid = clusters.len();
            for &idx in &comp {
                cluster_of_text[idx] = cid;
            }
            clusters.push(comp);
        } else {
            let mut buckets: HashMap<(i64, i64), Vec<usize>, FxBuild> = HashMap::default();
            for &idx in &comp {
                let (c, r) = text_coords[idx];
                buckets
                    .entry(((c - min_c) / 10, (r - min_r) / 6))
                    .or_default()
                    .push(idx);
            }
            let mut keys: Vec<(i64, i64)> = buckets.keys().copied().collect();
            keys.sort_unstable();
            for key in keys {
                let members = buckets.remove(&key).unwrap_or_default();
                let cid = clusters.len();
                for &idx in &members {
                    cluster_of_text[idx] = cid;
                }
                clusters.push(members);
            }
        }
    }
    (clusters, cluster_of_text)
}

pub struct Reverselife {
    config: ReverselifeConfig,
    history: Option<History>,
    left: i64,
    bottom: i64,
    width: usize,
    height: usize,
    /// Cells ever alive: (cell index, slot, column, symbol).
    cells: Vec<(usize, u32, usize, usize)>,
    /// Seed cells (alive in generation 0): (slot, base color index).
    seed_cells: Vec<(u32, usize)>,
    /// cell_visuals[(symbol * hues + hue) * FADE_LEVELS + brightness - 1],
    /// hues running smoothly around the cell colors.
    cell_visuals: Vec<Visual>,
    /// The ghost "·" by brightness - 1.
    ghosts: Vec<Visual>,
    text: Vec<u32>,
    text_coords: Vec<(i64, i64)>,
    /// Maps canvas cell -> index in `text`, or `u32::MAX` if empty.
    text_grid: Vec<u32>,
    /// Per text character: its gradient color, final, fade, flash, and warm visuals.
    text_color: Vec<Color>,
    text_final: Vec<Visual>,
    text_fade: Vec<Visual>,
    text_flash: Vec<Visual>,
    text_warm: Vec<Visual>,
    /// Letter clusters for impact flickers.
    clusters: Vec<Vec<usize>>,
    cluster_of_text: Vec<usize>,
    cluster_flicker: Vec<Option<ClusterFlicker>>,
    cluster_cooldown_until: Vec<i64>,
    /// Stray gliders sailing around the finished logo.
    arena: Arena,
    gliders: Vec<Glider>,
    glider_body: Vec<Visual>,
    glider_nose: Vec<Visual>,
    glider_trail1: Vec<Visual>,
    glider_flash: Visual,
    glider_dissolve: [Visual; 2],
    shown: Shown,
    frame: i64,
    reverse_end: i64,
    resolve_end: i64,
    end_frame: i64,
}

impl Reverselife {
    pub fn new(config: ReverselifeConfig) -> Self {
        Reverselife {
            config,
            history: None,
            left: 0,
            bottom: 0,
            width: 0,
            height: 0,
            cells: Vec::new(),
            seed_cells: Vec::new(),
            cell_visuals: Vec::new(),
            ghosts: Vec::new(),
            text: Vec::new(),
            text_coords: Vec::new(),
            text_grid: Vec::new(),
            text_color: Vec::new(),
            text_final: Vec::new(),
            text_fade: Vec::new(),
            text_flash: Vec::new(),
            text_warm: Vec::new(),
            clusters: Vec::new(),
            cluster_of_text: Vec::new(),
            cluster_flicker: Vec::new(),
            cluster_cooldown_until: Vec::new(),
            arena: Arena {
                left: 0,
                right: 0,
                bottom: 0,
                top: 0,
            },
            gliders: Vec::new(),
            glider_body: Vec::new(),
            glider_nose: Vec::new(),
            glider_trail1: Vec::new(),
            glider_flash: Visual(0),
            glider_dissolve: [Visual(0), Visual(0)],
            shown: Shown::Nothing,
            frame: 0,
            reverse_end: 0,
            resolve_end: 0,
            end_frame: 0,
        }
    }

    fn steps(&self) -> usize {
        self.config.simulation_steps as usize
    }

    fn show_grid(&mut self, e: &mut Engine, visible: bool) {
        for &(_, slot, _, _) in &self.cells {
            e.set_visible(slot, visible);
        }
    }

    fn show_text(&mut self, e: &mut Engine, visible: bool) {
        for &slot in &self.text {
            e.set_visible(slot, visible);
        }
    }

    fn hide_gliders(&self, e: &mut Engine) {
        for g in &self.gliders {
            for &slot in g
                .body_slots
                .iter()
                .chain(g.trail1_slots.iter())
                .chain(g.trail2_slots.iter())
            {
                e.set_visible(slot, false);
            }
        }
    }

    #[inline]
    fn text_at(&self, col: i64, row: i64) -> Option<usize> {
        if col < 0 || row < 0 || col >= self.width as i64 || row >= self.height as i64 {
            return None;
        }
        let idx = self.text_grid[row as usize * self.width + col as usize];
        (idx != u32::MAX).then_some(idx as usize)
    }

    fn cells_free_of_text(&self, cells: &[(i64, i64); 5]) -> bool {
        cells.iter().all(|&(c, r)| {
            (0..self.width as i64).contains(&c)
                && (0..self.height as i64).contains(&r)
                && self.text_at(c, r).is_none()
        })
    }

    fn trigger_cluster_flicker(&mut self, text_idx: usize, impact_col: i64, impact_row: i64) {
        let cid = self.cluster_of_text[text_idx];
        if cid >= self.clusters.len() {
            return;
        }
        if self.cluster_flicker[cid].is_some() || self.frame < self.cluster_cooldown_until[cid] {
            return;
        }
        let mut max_delay = 0i64;
        for &idx in &self.clusters[cid] {
            let (c, r) = self.text_coords[idx];
            let delay = ((c - impact_col).abs() + (r - impact_row).abs()) / 3;
            max_delay = max_delay.max(delay);
        }
        self.cluster_flicker[cid] = Some(ClusterFlicker {
            start_frame: self.frame,
            impact_col,
            impact_row,
            max_delay,
        });
        self.cluster_cooldown_until[cid] = self.frame + FLICKER_DURATION + max_delay + FLICKER_COOLDOWN;
    }

    /// Generations the chaos runs through before the rewind, ending at the last.
    fn chaos_span(&self) -> usize {
        let c = &self.config;
        ((c.chaos_hold_time / c.generation_time) as usize).min(self.steps() / 4)
    }

    /// The field at a fractional generation `position`, between the
    /// generation just shown and the next one: cells being born brighten in,
    /// dying cells dim out into a ghost "·", and the ghosts of the last few
    /// generations shown fade away, so nothing pops between generations.
    fn display_field(&mut self, e: &mut Engine, position: f64, rewinding: bool) {
        if self.shown != Shown::Field {
            self.show_text(e, false);
            self.shown = Shown::Field;
        }
        let steps = self.steps();
        let first = steps - self.chaos_span();
        let position = position.clamp(0.0, steps as f64);
        // from: the generation shown last, to: the next one, t: the way between
        let (from, to, t) = if rewinding {
            let from = (position.ceil() as usize).min(steps);
            (from, from.saturating_sub(1), from as f64 - position)
        } else {
            let from = (position.floor() as usize).min(steps);
            (from, (from + 1).min(steps), position - from as f64)
        };
        // the generations shown before, nearest first (the rewind turned at the last)
        let past: [Option<usize>; TRAIL + 1] = std::array::from_fn(|k| {
            if rewinding && from + k <= steps {
                Some(from + k)
            } else {
                let back = if rewinding { from + k - steps } else { k };
                let g = if rewinding { steps } else { from }.checked_sub(back)?;
                (g >= first).then_some(g)
            }
        });
        let history = self.history.as_ref().expect("built");
        let colors = self.config.cell_colors.len();
        let hues = colors * HUES;
        let width = self.width.max(1) as f64;
        let drift = position / 4.0;
        let level = |x: f64| ((x * FADE_LEVELS as f64).round() as usize).min(FADE_LEVELS);
        for &(cell, slot, column, symbol) in &self.cells {
            let brightness = match (history.alive(from, cell), history.alive(to, cell)) {
                (true, true) => 1.0,
                (true, false) => 1.0 - t,
                (false, true) => t,
                (false, false) => 0.0,
            };
            let ghost = if brightness >= GHOST_MAX {
                0.0
            } else {
                past.iter()
                    .enumerate()
                    .find(|&(_, g)| g.is_some_and(|g| history.alive(g, cell)))
                    .map_or(0.0, |(k, _)| {
                        let age = k as f64 + t;
                        GHOST_MAX * ((TRAIL as f64 + 1.0 - age) / TRAIL as f64).clamp(0.0, 1.0)
                    })
            };
            let visual = if brightness >= GHOST_MAX || (ghost <= 0.0 && brightness > 0.0) {
                let lit = level(brightness);
                let hue_at = column as f64 * colors as f64 / width + drift;
                let hue = ((hue_at * HUES as f64).floor() as usize) % hues;
                (lit > 0).then(|| self.cell_visuals[(symbol * hues + hue) * FADE_LEVELS + lit - 1])
            } else if ghost > 0.0 {
                let lit = level(brightness.max(ghost) / GHOST_MAX);
                (lit > 0).then(|| self.ghosts[lit - 1])
            } else {
                None
            };
            match visual {
                Some(visual) => {
                    e.set_visual(slot, visual);
                    e.set_visible(slot, true);
                }
                None => e.set_visible(slot, false),
            }
        }
    }

    /// The seed silhouette brightening towards white.
    fn display_pulse(&mut self, e: &mut Engine, pulse: f64) {
        let level = ((pulse * 1.35).min(1.0) * LEVELS as f64) as usize;
        let symbol = if pulse < 0.45 { "◆" } else { "✦" };
        let key = level * 2 + usize::from(pulse >= 0.45);
        if self.shown == Shown::Pulse(key) {
            return;
        }
        if !matches!(self.shown, Shown::Pulse(_)) {
            self.show_text(e, false);
            self.show_grid(e, false);
        }
        self.shown = Shown::Pulse(key);
        let white = Color::from_rgb(255, 255, 255);
        let brightness = level as f64 / LEVELS as f64;
        let visuals: Vec<Visual> = self
            .config
            .cell_colors
            .clone()
            .iter()
            .map(|base| {
                let color = shift_color_towards(base, &white, brightness).unwrap_or(white);
                plain(e, symbol, color)
            })
            .collect();
        for &(slot, base) in &self.seed_cells {
            e.set_visual(slot, visuals[base]);
            e.set_visible(slot, true);
        }
    }

    /// The glyphs cooling from the white of the pulse into their final colors.
    fn display_fade(&mut self, e: &mut Engine, progress: f64) {
        let eased = 1.0 - (1.0 - progress).powi(3);
        let level = (eased * LEVELS as f64).round() as usize;
        if !matches!(self.shown, Shown::Fade(_)) {
            self.show_grid(e, false);
            self.show_text(e, true);
        }
        if self.shown != Shown::Fade(level) {
            self.shown = Shown::Fade(level);
            let start = Color::from_rgb(255, 255, 255);
            for i in 0..self.text.len() {
                let visual = if level >= LEVELS {
                    self.text_final[i]
                } else {
                    let color = shift_color_towards(
                        &start,
                        &self.text_color[i],
                        level as f64 / LEVELS as f64,
                    )
                    .unwrap_or(self.text_color[i]);
                    text_visual(e, self.text[i], Some(color), None)
                };
                self.text_fade[i] = visual;
                e.set_visual(self.text[i], visual);
            }
        }
    }

    /// Signature flourish: stray Conway gliders sail around the finished logo
    /// with faint ghost trails, bouncing off letters and making each touched
    /// letter flicker off and back on once before dissolving cleanly.
    fn display_final(&mut self, e: &mut Engine) {
        if self.shown != Shown::Final {
            self.show_grid(e, false);
            self.show_text(e, true);
            for (i, &slot) in self.text.iter().enumerate() {
                e.set_visual(slot, self.text_final[i]);
            }
            self.shown = Shown::Final;
        }

        if self.frame >= self.end_frame {
            self.hide_gliders(e);
            for (cid, fl) in self.cluster_flicker.iter_mut().enumerate() {
                if fl.take().is_some() {
                    for &idx in &self.clusters[cid] {
                        let slot = self.text[idx];
                        e.set_visual(slot, self.text_final[idx]);
                        e.set_visible(slot, true);
                    }
                }
            }
            return;
        }

        let hold_elapsed = self.frame - self.resolve_end;
        let hold_remaining = self.end_frame - self.frame;
        let allow_flicker = hold_remaining > FLICKER_DURATION + 16;

        // 1. Advance gliders and collect any letter impacts.
        let mut impacts: Vec<(usize, i64, i64)> = Vec::new();
        let arena = self.arena;
        let width = self.width as i64;
        let height = self.height as i64;

        for gi in 0..self.gliders.len() {
            if hold_elapsed < self.gliders[gi].spawn_delay {
                continue;
            }
            if self.gliders[gi].bounce_flash > 0 {
                self.gliders[gi].bounce_flash -= 1;
            }
            let dissolve_age = (hold_elapsed - self.gliders[gi].dissolve_start).max(0);
            if dissolve_age >= 24 {
                continue;
            }
            if (hold_elapsed + self.gliders[gi].step_offset) % GLIDER_STEP_FRAMES != 0 {
                continue;
            }

            let (ac, ar, dx, dy, phase) = {
                let g = &self.gliders[gi];
                (g.anchor_col, g.anchor_row, g.dx, g.dy, g.phase)
            };
            let prev_cells = glider_cells(ac, ar, dx, dy, phase);
            let (nc, nr, nphase) = if phase < 3 {
                (ac, ar, phase + 1)
            } else {
                (ac + dx, ar + dy, 0)
            };
            let next_cells = glider_cells(nc, nr, dx, dy, nphase);

            // Check if any cell hits the logo text.
            let mut hit: Option<(usize, i64, i64)> = None;
            for &(c, r) in &next_cells {
                if let Some(text_idx) = self.text_at(c, r) {
                    hit = Some((text_idx, c, r));
                    break;
                }
            }

            if let Some((text_idx, hc, hr)) = hit {
                if allow_flicker {
                    impacts.push((text_idx, hc, hr));
                }
                // Choose a reflection that clears the text cleanly.
                let prefer_y_flip = (hr - ar).abs() >= (hc - ac).abs();
                let candidates = if prefer_y_flip {
                    [(dx, -dy), (-dx, dy), (-dx, -dy)]
                } else {
                    [(-dx, dy), (dx, -dy), (-dx, -dy)]
                };
                let mut bounced = None;
                for (cdx, cdy) in candidates {
                    let test_c = (ac + cdx).clamp(1, (width - 2).max(1));
                    let test_r = (ar + cdy).clamp(1, (height - 2).max(1));
                    let test_cells = glider_cells(test_c, test_r, cdx, cdy, 0);
                    if self.cells_free_of_text(&test_cells) {
                        bounced = Some((test_c, test_r, cdx, cdy));
                        break;
                    }
                }
                let g = &mut self.gliders[gi];
                g.bounce_flash = 10;
                g.trail2_pos = g.trail1_pos;
                g.trail1_pos = prev_cells.map(Some);
                if let Some((bc, br, bdx, bdy)) = bounced {
                    g.anchor_col = bc;
                    g.anchor_row = br;
                    g.dx = bdx;
                    g.dy = bdy;
                    g.phase = 0;
                } else {
                    g.dx = -dx;
                    g.dy = -dy;
                    g.phase = 0;
                }
            } else {
                let out_x = next_cells
                    .iter()
                    .any(|&(c, _)| c < arena.left || c > arena.right);
                let out_y = next_cells
                    .iter()
                    .any(|&(_, r)| r < arena.bottom || r > arena.top);
                if (out_x || out_y) && dissolve_age == 0 {
                    let ndx = if out_x { -dx } else { dx };
                    let ndy = if out_y { -dy } else { dy };
                    let g = &mut self.gliders[gi];
                    g.trail2_pos = g.trail1_pos;
                    g.trail1_pos = prev_cells.map(Some);
                    g.dx = ndx;
                    g.dy = ndy;
                    g.anchor_col = ac.clamp(arena.left + 1, (arena.right - 1).max(arena.left + 1));
                    g.anchor_row = ar.clamp(arena.bottom + 1, (arena.top - 1).max(arena.bottom + 1));
                    g.phase = 0;
                } else {
                    let g = &mut self.gliders[gi];
                    g.trail2_pos = g.trail1_pos;
                    g.trail1_pos = prev_cells.map(Some);
                    g.anchor_col = nc;
                    g.anchor_row = nr;
                    g.phase = nphase;
                }
            }
        }

        for (text_idx, hc, hr) in impacts {
            self.trigger_cluster_flicker(text_idx, hc, hr);
        }

        // 2. Render gliders and their 2-generation ghost trails (incremental, local).
        for gi in 0..self.gliders.len() {
            let g = &self.gliders[gi];
            let dissolve_age = (hold_elapsed - g.dissolve_start).max(0);
            if hold_elapsed < g.spawn_delay || dissolve_age >= 24 {
                for &slot in g
                    .body_slots
                    .iter()
                    .chain(g.trail1_slots.iter())
                    .chain(g.trail2_slots.iter())
                {
                    e.set_visible(slot, false);
                }
                continue;
            }

            let body = glider_cells(g.anchor_col, g.anchor_row, g.dx, g.dy, g.phase);
            for (k, &(c, r)) in body.iter().enumerate() {
                let slot = g.body_slots[k];
                if (0..width).contains(&c)
                    && (0..height).contains(&r)
                    && self.text_at(c, r).is_none()
                {
                    let visual = if dissolve_age >= 12 {
                        self.glider_dissolve[1]
                    } else if dissolve_age > 0 {
                        self.glider_dissolve[0]
                    } else if g.bounce_flash > 0 {
                        self.glider_flash
                    } else if k == 0 {
                        self.glider_nose[g.color_idx]
                    } else {
                        self.glider_body[g.color_idx]
                    };
                    e.set_coordinate(slot, Coord::new(self.left + c, self.bottom + r));
                    e.set_visual(slot, visual);
                    e.set_visible(slot, true);
                } else {
                    e.set_visible(slot, false);
                }
            }

            let show_trails = dissolve_age <= 4;
            for (k, pos) in g.trail1_pos.iter().enumerate() {
                let slot = g.trail1_slots[k];
                if show_trails {
                    if let Some((c, r)) = *pos {
                        if (0..width).contains(&c)
                            && (0..height).contains(&r)
                            && self.text_at(c, r).is_none()
                            && !body.contains(&(c, r))
                        {
                            e.set_coordinate(slot, Coord::new(self.left + c, self.bottom + r));
                            e.set_visual(slot, self.glider_trail1[g.color_idx]);
                            e.set_visible(slot, true);
                            continue;
                        }
                    }
                }
                e.set_visible(slot, false);
            }

            for (k, pos) in g.trail2_pos.iter().enumerate() {
                let slot = g.trail2_slots[k];
                if show_trails {
                    if let Some((c, r)) = *pos {
                        if (0..width).contains(&c)
                            && (0..height).contains(&r)
                            && self.text_at(c, r).is_none()
                            && !body.contains(&(c, r))
                            && !g.trail1_pos.contains(&Some((c, r)))
                        {
                            e.set_coordinate(slot, Coord::new(self.left + c, self.bottom + r));
                            e.set_visual(slot, self.glider_dissolve[1]);
                            e.set_visible(slot, true);
                            continue;
                        }
                    }
                }
                e.set_visible(slot, false);
            }
        }

        // 3. Update active letter-cluster flickers.
        for cid in 0..self.cluster_flicker.len() {
            let Some(fl) = self.cluster_flicker[cid] else {
                continue;
            };
            let elapsed = self.frame - fl.start_frame;
            if elapsed >= FLICKER_DURATION + fl.max_delay {
                for &idx in &self.clusters[cid] {
                    let slot = self.text[idx];
                    e.set_visual(slot, self.text_final[idx]);
                    e.set_visible(slot, true);
                }
                self.cluster_flicker[cid] = None;
                continue;
            }
            for &idx in &self.clusters[cid] {
                let (c, r) = self.text_coords[idx];
                let delay = ((c - fl.impact_col).abs() + (r - fl.impact_row).abs()) / 3;
                let age = elapsed - delay;
                let slot = self.text[idx];
                if age < 0 || age >= FLICKER_DURATION {
                    e.set_visual(slot, self.text_final[idx]);
                    e.set_visible(slot, true);
                } else if age < 3 {
                    e.set_visual(slot, self.text_flash[idx]);
                    e.set_visible(slot, true);
                } else if age < 13 {
                    e.set_visible(slot, false);
                } else if age < 19 {
                    e.set_visual(slot, self.text_flash[idx]);
                    e.set_visible(slot, true);
                } else {
                    e.set_visual(slot, self.text_warm[idx]);
                    e.set_visible(slot, true);
                }
            }
        }
    }
}

impl Hooks for Reverselife {}

impl Effect for Reverselife {
    fn build(&mut self, e: &mut Engine) -> Result<(), EngineError> {
        let canvas = e.canvas.clone();
        let (left, bottom) = (canvas.left, canvas.bottom);
        let width = (canvas.right - left + 1).max(0) as usize;
        let height = (canvas.top - bottom + 1).max(0) as usize;
        self.left = left;
        self.bottom = bottom;
        self.width = width;
        self.height = height;
        let dynamic = e.existing_color_handling() == ExistingColorHandling::Dynamic;
        let always = e.existing_color_handling() == ExistingColorHandling::Always;

        let gradient = Gradient::new(
            &self.config.final_gradient_stops,
            &self.config.final_gradient_steps,
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
                self.config.final_gradient_direction,
            )
            .map_err(other)?;
        let fallback = self.config.final_gradient_stops[0];
        let ice_white = Color::from_rgb(224, 242, 254);
        let glow_bg = Color::from_rgb(12, 45, 68);

        self.text = e.get_characters(
            CharacterFilter::default(),
            CharacterSort::TopToBottomLeftToRight,
        );
        let mut seed = vec![false; width * height];
        self.text_grid = vec![u32::MAX; width * height];
        let (mut min_c, mut max_c, mut min_r, mut max_r) = (i64::MAX, i64::MIN, i64::MAX, i64::MIN);
        for (i, &slot) in self.text.clone().iter().enumerate() {
            let coord = e.input_coord(slot);
            let (column, row) = (coord.column - left, coord.row - bottom);
            self.text_coords.push((column, row));
            if (0..width as i64).contains(&column) && (0..height as i64).contains(&row) {
                let cell_idx = row as usize * width + column as usize;
                seed[cell_idx] = true;
                self.text_grid[cell_idx] = i as u32;
                min_c = min_c.min(column);
                max_c = max_c.max(column);
                min_r = min_r.min(row);
                max_r = max_r.max(row);
            }
            let color = mapping.get(&coord).copied().unwrap_or(fallback);
            let (final_visual, target, flash_bg) = if dynamic {
                let (fg, bg) = (e.input_fg(slot), e.input_bg(slot));
                (text_visual(e, slot, fg, bg), fg.unwrap_or(color), bg)
            } else {
                let bg = if always { None } else { Some(glow_bg) };
                (text_visual(e, slot, Some(color), None), color, bg)
            };
            let flash_fg = shift_color_towards(&target, &ice_white, 0.78).unwrap_or(ice_white);
            let warm_fg = shift_color_towards(&target, &ice_white, 0.32).unwrap_or(target);
            self.text_color.push(target);
            self.text_final.push(final_visual);
            self.text_fade.push(final_visual);
            self.text_flash
                .push(text_visual(e, slot, Some(flash_fg), flash_bg));
            self.text_warm.push(text_visual(
                e,
                slot,
                Some(warm_fg),
                if dynamic { e.input_bg(slot) } else { None },
            ));
            e.set_visible(slot, false);
        }

        let (clusters, cluster_of_text) =
            build_letter_clusters(&self.text_coords, &self.text_grid, width, height);
        self.cluster_flicker = vec![None; clusters.len()];
        self.cluster_cooldown_until = vec![0; clusters.len()];
        self.clusters = clusters;
        self.cluster_of_text = cluster_of_text;

        let sparks = plan_sparks(e, &seed, width, height, self.steps());
        let history = simulate(seed, width, height, self.steps(), &sparks);
        // a character for every cell that is ever alive
        let mut ever = vec![0u64; history.words];
        for bits in &history.stored {
            for (w, b) in ever.iter_mut().zip(bits) {
                *w |= b;
            }
        }
        let colors = self.config.cell_colors.len();
        let first_symbol = self.config.cell_symbols[0].clone();
        for (w, &word) in ever.iter().enumerate() {
            let mut word = word;
            while word != 0 {
                let cell = w * 64 + word.trailing_zeros() as usize;
                word &= word - 1;
                let (row, column) = (cell / width, cell % width);
                let coord = Coord::new(left + column as i64, bottom + row as i64);
                let slot = e.add_character(&first_symbol, coord);
                e.set_layer(slot, 3);
                // a symbol per cell, kept for its whole life (scrambled so it
                // does not run in stripes)
                let symbol = (cell.wrapping_mul(0x9E37_79B9) >> 7) % self.config.cell_symbols.len();
                self.cells.push((cell, slot, column, symbol));
                if history.alive(0, cell) {
                    let base = (column * colors / width.max(1)).min(colors - 1);
                    self.seed_cells.push((slot, base));
                }
            }
        }
        let black = Color::from_rgb(0, 0, 0);
        let dim = |color: &Color, lit: usize| {
            shift_color_towards(color, &black, 1.0 - lit as f64 / FADE_LEVELS as f64)
                .unwrap_or(*color)
        };
        let palette = self.config.cell_colors.clone();
        for symbol in self.config.cell_symbols.clone() {
            for hue in 0..colors * HUES {
                let (stop, step) = (hue / HUES, hue % HUES);
                let base = shift_color_towards(
                    &palette[stop],
                    &palette[(stop + 1) % colors],
                    step as f64 / HUES as f64,
                )
                .unwrap_or(palette[stop]);
                for lit in 1..=FADE_LEVELS {
                    let visual = plain(e, &symbol, dim(&base, lit));
                    self.cell_visuals.push(visual);
                }
            }
        }
        for lit in 1..=FADE_LEVELS {
            let visual = plain(e, "·", dim(&palette[0], lit));
            self.ghosts.push(visual);
        }
        self.history = Some(history);

        // Pre-build glider visuals using crisp block elements matching reverselife's palette.
        let white = Color::from_rgb(248, 250, 252);
        let dark_base = Color::from_rgb(10, 22, 36);
        for color in self.config.cell_colors.clone() {
            let bright = shift_color_towards(&color, &white, 0.22).unwrap_or(color);
            let nose = shift_color_towards(&color, &white, 0.58).unwrap_or(white);
            let trail = shift_color_towards(&color, &dark_base, 0.42).unwrap_or(color);
            self.glider_body.push(plain(e, "█", bright));
            self.glider_nose.push(plain(e, "█", nose));
            self.glider_trail1.push(plain(e, "▒", trail));
        }
        self.glider_flash = plain(e, "█", white);
        let dissolve_mid = shift_color_towards(&self.config.cell_colors[0], &white, 0.25)
            .unwrap_or(self.config.cell_colors[0]);
        self.glider_dissolve = [
            plain(e, "▒", dissolve_mid),
            plain(e, "░", self.config.cell_colors[0]),
        ];

        // Plan the orbital arena and spawn stray Conway gliders around the logo.
        let c = &self.config;
        self.reverse_end = c.chaos_hold_time + (c.simulation_steps + 1) * c.generation_time;
        self.resolve_end = self.reverse_end + c.resolve_duration;
        self.end_frame = self.resolve_end + c.final_hold_time;
        self.frame = 0;

        if width >= 9 && height >= 7 && min_c <= max_c && c.final_hold_time >= 30 {
            let pad_x = ((width as i64) / 10).clamp(5, 22);
            let pad_y = ((height as i64) / 5).clamp(4, 9);
            let arena_left = (min_c - pad_x).max(1);
            let arena_right = (max_c + pad_x).min(width as i64 - 2);
            let arena_bottom = (min_r - pad_y).max(1);
            let arena_top = (max_r + pad_y).min(height as i64 - 2);
            self.arena = Arena {
                left: arena_left,
                right: arena_right,
                bottom: arena_bottom,
                top: arena_top,
            };

            let desired = if width < 120 {
                4
            } else if width < 260 {
                5
            } else {
                6
            };
            let text_w = (max_c - min_c + 1).max(1);
            let mid_c = (min_c + max_c) / 2;
            let top_y = (max_r + 3).min(arena_top - 1).max(1);
            let bot_y = (min_r - 3).max(arena_bottom + 1).min(height as i64 - 2);

            // Launch zones distributed around the logo, aimed inward so gliders
            // sail across the silhouette and bounce off different letters.
            let zones: [(i64, i64, i64, i64); 6] = [
                (min_c + text_w / 8, top_y, 1, -1),
                (max_c - text_w / 8, bot_y, -1, 1),
                (max_c - text_w / 6, top_y, -1, -1),
                (min_c + text_w / 6, bot_y, 1, 1),
                (mid_c - 3, top_y, 1, -1),
                (mid_c + 3, bot_y, -1, 1),
            ];
            let dissolve_window = (c.final_hold_time / 5).clamp(28, 64);

            for (zi, &(base_c, base_r, dx, dy)) in zones.iter().take(desired).enumerate() {
                let jitter_c = e.rng.randint(-3, 3);
                let jitter_r = e.rng.randint(-1, 1);
                let start_c = (base_c + jitter_c).clamp(arena_left + 1, (arena_right - 1).max(arena_left + 1));
                let start_r = (base_r + jitter_r).clamp(arena_bottom + 1, (arena_top - 1).max(arena_bottom + 1));

                // Find a nearby empty spot so the glider spawns cleanly outside text.
                let mut chosen = None;
                'search: for radius in 0..=5i64 {
                    for dr in -radius..=radius {
                        for dc in -radius..=radius {
                            if radius > 0 && dc.abs() != radius && dr.abs() != radius {
                                continue;
                            }
                            let tc = start_c + dc;
                            let tr = start_r + dr;
                            if tc <= 1 || tc >= width as i64 - 2 || tr <= 1 || tr >= height as i64 - 2 {
                                continue;
                            }
                            let cells = glider_cells(tc, tr, dx, dy, 0);
                            if self.cells_free_of_text(&cells) {
                                chosen = Some((tc, tr));
                                break 'search;
                            }
                        }
                    }
                }
                let Some((ac, ar)) = chosen else {
                    continue;
                };

                let mut body_slots = [0u32; 5];
                let mut trail1_slots = [0u32; 5];
                let mut trail2_slots = [0u32; 5];
                let origin = Coord::new(left + ac, bottom + ar);
                for k in 0..5 {
                    let b = e.add_character("█", origin);
                    e.set_layer(b, 4);
                    e.set_visible(b, false);
                    body_slots[k] = b;

                    let t1 = e.add_character("▒", origin);
                    e.set_layer(t1, 2);
                    e.set_visible(t1, false);
                    trail1_slots[k] = t1;

                    let t2 = e.add_character("░", origin);
                    e.set_layer(t2, 2);
                    e.set_visible(t2, false);
                    trail2_slots[k] = t2;
                }

                // Prefer brighter cell colors (later stops in cell_colors).
                let color_idx = if colors >= 2 {
                    colors - 1 - (zi % (colors.min(3)))
                } else {
                    0
                };
                let spawn_delay = (zi as i64 * 6).min(c.final_hold_time / 4);
                let dissolve_stagger = (zi as i64 * 5) % 16;
                let dissolve_start = (c.final_hold_time - dissolve_window + dissolve_stagger)
                    .max(spawn_delay + 12)
                    .min((c.final_hold_time - 25).max(0));

                self.gliders.push(Glider {
                    anchor_col: ac,
                    anchor_row: ar,
                    dx,
                    dy,
                    phase: zi % 4,
                    spawn_delay,
                    step_offset: zi as i64 % GLIDER_STEP_FRAMES,
                    bounce_flash: 0,
                    dissolve_start,
                    color_idx,
                    body_slots,
                    trail1_slots,
                    trail2_slots,
                    trail1_pos: [None; 5],
                    trail2_pos: [None; 5],
                });
            }
        }
        Ok(())
    }

    fn next_frame(&mut self, e: &mut Engine) -> bool {
        if self.frame > self.end_frame {
            return false;
        }
        let c = &self.config;
        let steps = self.steps();
        if self.frame < c.chaos_hold_time {
            // the chaos runs on into its most evolved generation
            let span = self.chaos_span();
            let position = (steps - span) as f64
                + span as f64 * self.frame as f64 / c.chaos_hold_time as f64;
            self.display_field(e, position, false);
        } else if self.frame < self.reverse_end {
            // played backward, quick through the chaos and slowing down as
            // the field draws together into the silhouette
            let length = (self.reverse_end - c.chaos_hold_time) as f64;
            let left = 1.0 - (self.frame - c.chaos_hold_time) as f64 / length;
            self.display_field(e, steps as f64 * left.powf(REWIND_EASE), true);
        } else if self.frame < self.resolve_end {
            let elapsed = self.frame - self.reverse_end;
            let pulse_duration = (c.resolve_duration / 5).max(1);
            if elapsed < pulse_duration {
                self.display_pulse(e, elapsed as f64 / pulse_duration as f64);
            } else {
                let color_duration = (c.resolve_duration - pulse_duration).max(1);
                let progress =
                    ((elapsed - pulse_duration) as f64 / color_duration as f64).clamp(0.0, 1.0);
                self.display_fade(e, progress);
            }
        } else {
            self.display_final(e);
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
        config: ReverselifeConfig,
    }

    fn config(args: &[&str]) -> ReverselifeConfig {
        let mut all = vec!["reverselife"];
        all.extend_from_slice(args);
        Cli::parse_from(all).config
    }

    /// Run to completion; the frame count, and per slot (visible, coord,
    /// visual) at the end.
    fn run(
        input: &str,
        width: i64,
        height: i64,
        handling: ExistingColorHandling,
        args: &[&str],
    ) -> Option<(u64, Engine, Vec<(bool, Coord, Visual)>)> {
        let terminal = TerminalConfig {
            canvas_width: if width == 0 { -1 } else { width },
            canvas_height: if height == 0 { -1 } else { height },
            ignore_terminal_dimensions: true,
            existing_color_handling: handling,
            ..TerminalConfig::default()
        };
        // the CLI turns blank input away before any effect runs
        let mut e = Engine::new(
            input,
            terminal,
            Rng::seeded(7),
            Clock::virtual_with_frame_rate(60),
        )
        .ok()?;
        let mut effect = Reverselife::new(config(args));
        effect.build(&mut e).expect("build");
        let mut frames = 0u64;
        while effect.next_frame(&mut e) {
            e.render_here();
            frames += 1;
            assert!(frames < 1_000_000, "reverselife does not end");
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
            let (_, e, _) = run(input, w, h, ExistingColorHandling::Ignore, &[])
                .unwrap_or_else(|| panic!("no engine for {input:?}"));
            check_final(&e, false);
        }
    }

    #[test]
    fn dynamic_and_always_keep_input_colors() {
        let input = "\x1b[38;2;255;0;0mred\x1b[0m plain";
        let (_, e, _) = run(input, 0, 0, ExistingColorHandling::Dynamic, &[]).expect("engine");
        check_final(&e, true);
        assert!(e.input_chars.iter().any(|&s| {
            e.visual_info(e.current_visual(s))
                .fg
                .is_some_and(|c| c.rgb_ints() == (255, 0, 0))
        }));
        let (_, e, _) = run(input, 0, 0, ExistingColorHandling::Always, &[]).expect("engine");
        check_final(&e, true);
    }

    #[test]
    fn every_timing_option_moves_the_end() {
        let input = "OMARCHY\nhello";
        let (base, _, _) = run(input, 0, 0, ExistingColorHandling::Ignore, &[]).expect("engine");
        for option in [
            "--simulation-steps",
            "--generation-time",
            "--chaos-hold-time",
            "--resolve-duration",
            "--final-hold-time",
        ] {
            let (frames, e, _) =
                run(input, 0, 0, ExistingColorHandling::Ignore, &[option, "500"]).expect("engine");
            assert!(frames > base, "{option} does not lengthen the run");
            check_final(&e, false);
        }
    }

    #[test]
    fn same_seed_same_run() {
        let input = "OMARCHY\nhello world";
        let (fa, _, a) = run(
            input,
            30,
            8,
            ExistingColorHandling::Ignore,
            &["--simulation-steps", "20"],
        )
        .expect("engine");
        let (fb, _, b) = run(
            input,
            30,
            8,
            ExistingColorHandling::Ignore,
            &["--simulation-steps", "20"],
        )
        .expect("engine");
        assert_eq!(fa, fb);
        assert_eq!(a, b);
    }

    #[test]
    fn single_options() {
        let (_, e, _) = run(
            "hi there",
            0,
            0,
            ExistingColorHandling::Ignore,
            &[
                "--cell-symbols",
                "#",
                "--cell-colors",
                "ff0000",
                "--final-gradient-stops",
                "00ff00",
            ],
        )
        .expect("engine");
        check_final(&e, false);
    }

    #[test]
    fn small_inputs_keep_the_screen_busy_through_the_rewind() {
        for input in ["x", "hello", "OMARCHY\nis\nhere"] {
            let terminal = TerminalConfig {
                canvas_width: 96,
                canvas_height: 24,
                ignore_terminal_dimensions: true,
                ..TerminalConfig::default()
            };
            let mut e = Engine::new(
                input,
                terminal,
                Rng::seeded(7),
                Clock::virtual_with_frame_rate(60),
            )
            .expect("engine");
            let mut effect = Reverselife::new(config(&[]));
            effect.build(&mut e).expect("build");
            let (hold, end) = (effect.config.chaos_hold_time, effect.reverse_end);
            let steps = effect.steps();
            let history = effect.history.as_ref().expect("built");
            // frames shown with a nearly empty field, before and in the rewind
            let mut thin = 0;
            for frame in 0..end {
                let generation = if frame < hold {
                    steps
                } else {
                    let left = 1.0 - (frame - hold) as f64 / (end - hold) as f64;
                    (steps as f64 * left.powf(REWIND_EASE)).round() as usize
                };
                let alive = (0..96 * 24)
                    .filter(|&c| history.alive(generation, c))
                    .count();
                if alive < 12 {
                    thin += 1;
                }
            }
            assert!(
                thin * 4 < end - hold,
                "{input:?}: {thin} of {end} frames show a nearly empty field"
            );
        }
    }

    #[test]
    fn cycles_replay_like_a_full_simulation() {
        // a blinker: period 2 from generation 0
        let mut seed = vec![false; 25];
        for c in [11, 12, 13] {
            seed[c] = true;
        }
        let h = simulate(seed, 5, 5, 50, &[]);
        assert_eq!(h.cycle, Some((0, 2)));
        assert_eq!(h.stored.len(), 2);
        assert!(h.alive(50, 12) && h.alive(49, 12));
        assert!(h.alive(50, 11) && !h.alive(49, 11));
    }
}
