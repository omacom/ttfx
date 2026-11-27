//! automata: an elementary cellular automaton grows down the canvas into a
//! fractal lattice, then pours itself into the text.
//!
//! Original effect by Lukas Innig (@derluke), https://github.com/derluke/ttfx, MIT.
//! Rewritten for the fx engine; every character is driven by hand each frame
//! (no scenes or paths), the way the original drove the old engine.
//!
//! Timeline: one generation per canvas row, top down, each shown
//! `generation-time` frames after the last. The newest generation burns
//! white and cools into the cell palette, and a colour wave keeps rolling
//! down the lattice at the speed it grew. The lattice holds for `hold-time`
//! frames, then resolves over `dissolve-duration` frames: the text ignites
//! outward from where the lattice touches it, while the cells, nearest the
//! lettering first, are drawn into their nearest glyph, which sparks as
//! each one lands. Once settled, a slow Rule-30 CRT refresh scanline sweeps
//! top-to-bottom across the logo during `final-hold-time`, exciting each row
//! bright with phosphor afterglow before the last frame rests clean.

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
use crate::fx::{Engine, Hooks, Sym, Visual};
use crate::utils::geometry::Coord;
use crate::utils::graphics::{shift_color_towards, Color, ColorPair, Gradient, GradientDirection};

#[derive(Args, Debug, Clone)]
pub struct AutomataConfig {
    /// Elementary cellular automaton rule, from 0 to 255. Rule 90 produces a Sierpinski triangle.
    #[arg(long = "rule", default_value_t = 90)]
    pub rule: u8,

    /// Number of evenly spaced living cells in the initial generation.
    #[arg(long = "seed-cells", default_value_t = 1, value_parser = parse_positive_int)]
    pub seed_cells: i64,

    /// Frames to display before adding each new generation.
    #[arg(long = "generation-time", default_value_t = 8, value_parser = parse_positive_int)]
    pub generation_time: i64,

    /// Frames to hold the completed cellular pattern.
    #[arg(long = "hold-time", default_value_t = 150, value_parser = parse_non_negative_int)]
    pub hold_time: i64,

    /// Frames over which the cellular pattern dissolves into the text.
    #[arg(long = "dissolve-duration", default_value_t = 420, value_parser = parse_positive_int)]
    pub dissolve_duration: i64,

    /// Frames to hold the readable text after the fractal has flowed into it.
    #[arg(long = "final-hold-time", default_value_t = 360, value_parser = parse_non_negative_int)]
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

/// A flying cell's glyph: `◆`, then `•`, then `·` as it nears its glyph.
const FLIGHT_SYMBOLS: [&str; 3] = ["◆", "•", "·"];
/// Steps of the looped cell palette between two adjacent stops.
const WAVE_STEPS: i64 = 8;
/// Palette steps between two adjacent generations in the colour wave.
const WAVE_PER_GENERATION: f64 = 2.0;
/// Generations behind the growth front that still burn white, then hot.
const WHITE_GENERATIONS: f64 = 1.0;
const HOT_GENERATIONS: f64 = 3.0;
/// Shares of the dissolve: the spread of cell departures by distance to the
/// text, their random jitter, the length of one cell's flight, and the
/// spread of the text's ignition by distance to the lattice.
const DEPART_SPREAD: f64 = 0.55;
const DEPART_JITTER: f64 = 0.12;
const FLIGHT: f64 = 0.30;
const IGNITE_SPREAD: f64 = 0.70;
const IGNITE_JITTER: f64 = 0.04;
/// Frames an igniting glyph shows white, then hot, and a landing spark.
const IGNITE_WHITE: i64 = 4;
const IGNITE_HOT: i64 = 14;
const SPARK: i64 = 5;
/// Rule-30 CRT refresh flourish: rows of phosphor trail behind the scanline,
/// and the normalized [0, 1) window within `final-hold-time` during which the
/// scanline sweeps top-to-bottom across the text.
const SCAN_TRAIL_ROWS: usize = 4;
const SCAN_START_SHARE: f64 = 0.08;
const SCAN_END_SHARE: f64 = 0.86;
const SCAN_RULE: u8 = 30;
const SCAN_WARMUP_GENS: usize = 2;

struct Cell {
    slot: u32,
    coord: Coord,
    generation: i64,
    /// When, as a share of the dissolve, the cell leaves; in [0, 1 - FLIGHT].
    depart: f64,
    destination: Coord,
    /// The glyph it flies into, if any.
    target: Option<u32>,
    /// Palette index frozen when it leaves.
    color: usize,
    /// 0 still, 1 flying, 2 gone.
    phase: u8,
}

struct Glyph {
    slot: u32,
    home: Coord,
    /// The frame it ignites.
    ignite: i64,
    /// Flashes white until this frame: a cell landed.
    spark_until: i64,
    shadow: Visual,
    hot: Visual,
    settled: Visual,
    white: Visual,
    /// Rule-30 CRT scanline excitation visuals: white-hot + subtle phosphor bg
    /// on active Rule-30 cells, bright cyan wake, and cool palette wake.
    crt_beam_on: Visual,
    crt_wake_bright: Visual,
    crt_wake_cool: Visual,
}

/// Precomputed Rule-30 CRT refresh scanline state scoped to the text bounds.
struct Scanline {
    left: i64,
    top: i64,
    width: usize,
    rows: usize,
    /// `[row * width + col]` Rule-30 living bits.
    bits: Vec<bool>,
    /// `[row * width + col]` true where a non-space input glyph sits.
    occupied: Vec<bool>,
    /// `[trail_row * width + col]` reusable helper slots (`SCAN_TRAIL_ROWS * width`).
    slots: Vec<u32>,
    /// Leading beam visuals for Rule-30 living cells (upper/lower half block for
    /// smooth sub-row motion) and faint horizontal trace for dead cells.
    beam_on_hi: Visual,
    beam_on_lo: Visual,
    beam_off: Visual,
    /// Trailing phosphor visuals for `dy = 1, 2, 3`.
    trail: [Visual; 3],
    /// Left/right CRT horizontal sync brackets for `dy = 0, 1, 2`.
    sync_left: [Visual; 3],
    sync_right: [Visual; 3],
    /// Whether any scanline helper slots are currently visible.
    active: bool,
    /// Whether the flourish has already settled back to clean state.
    cleaned: bool,
}

pub struct Automata {
    config: AutomataConfig,
    cells: Vec<Cell>,
    text: Vec<Glyph>,
    /// [cell symbol][palette index] visuals: cool, hot (half white), white.
    cool: Vec<Vec<Visual>>,
    hot: Vec<Vec<Visual>>,
    white: Vec<Visual>,
    /// [palette index][flight symbol] visuals, the last symbol white-hot.
    flying: Vec<[Visual; 3]>,
    scan: Option<Scanline>,
    frame: i64,
    dissolve_start: i64,
    end_frame: i64,
}

/// A visual for an input glyph: `colors`, unless the input's own colors
/// always win.
fn appearance(e: &mut Engine, slot: u32, sym: Sym, colors: ColorPair) -> Visual {
    let (mut fg, mut bg, mut attrs) = (colors.fg_color, colors.bg_color, HAS_COLORS);
    if e.existing_color_handling() == ExistingColorHandling::Always
        && e.uses_preexisting_colors(slot)
    {
        fg = e.input_fg(slot);
        bg = e.input_bg(slot);
        if e.input_bold(slot) {
            attrs |= BOLD;
        }
    }
    e.visuals
        .make(&e.symbols, VisualInfo { sym, fg, bg, attrs })
}

/// A plain colored visual for an added character.
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

fn toward(color: Color, target: Color, factor: f64) -> Color {
    shift_color_towards(&color, &target, factor).unwrap_or(target)
}

fn lerp(from: Coord, to: Coord, t: f64) -> Coord {
    Coord::new(
        (from.column as f64 + (to.column - from.column) as f64 * t).round() as i64,
        (from.row as f64 + (to.row - from.row) as f64 * t).round() as i64,
    )
}

impl Automata {
    pub fn new(config: AutomataConfig) -> Self {
        Automata {
            config,
            cells: Vec::new(),
            text: Vec::new(),
            cool: Vec::new(),
            hot: Vec::new(),
            white: Vec::new(),
            flying: Vec::new(),
            scan: None,
            frame: 0,
            dissolve_start: 0,
            end_frame: 0,
        }
    }

    fn next_generation(rule: u8, current: &[bool], next: &mut [bool]) {
        for index in 0..current.len() {
            let left = (index > 0 && current[index - 1]) as u8;
            let center = current[index] as u8;
            let right = (index + 1 < current.len() && current[index + 1]) as u8;
            next[index] = (rule >> ((left << 2) | (center << 1) | right)) & 1 == 1;
        }
    }

    /// The wave's palette index and symbol for a generation now.
    fn wave(&self, generation: i64) -> (usize, usize, f64) {
        let behind = self.frame as f64 / self.config.generation_time as f64 - generation as f64;
        let palette = self.flying.len() as f64;
        let color = (behind * WAVE_PER_GENERATION).floor().rem_euclid(palette) as usize;
        let symbols = self.cool.len() as i64;
        let symbol = (generation - (behind / 2.0).floor() as i64).rem_euclid(symbols) as usize;
        (color, symbol, behind)
    }

    fn living(&self, generation: i64) -> Visual {
        let (color, symbol, behind) = self.wave(generation);
        if behind < WHITE_GENERATIONS {
            self.white[symbol]
        } else if behind < HOT_GENERATIONS {
            self.hot[symbol][color]
        } else {
            self.cool[symbol][color]
        }
    }

    /// Living cells: the newest generations burn white, then hot, and the
    /// colour wave rolls down the lattice.
    fn live(&mut self, e: &mut Engine) {
        let time = self.config.generation_time;
        // cells are in generation order; one visual per generation
        let mut current = (-1, Visual(0));
        for index in 0..self.cells.len() {
            let (slot, generation) = (self.cells[index].slot, self.cells[index].generation);
            if self.frame < generation.saturating_mul(time) {
                break;
            }
            if current.0 != generation {
                current = (generation, self.living(generation));
            }
            e.set_visual(slot, current.1);
            e.set_visible(slot, true);
        }
    }

    fn dissolve(&mut self, e: &mut Engine) {
        let elapsed = self.frame - self.dissolve_start;
        let progress = (elapsed as f64 / self.config.dissolve_duration as f64).clamp(0.0, 1.0);
        let mut current = (-1, 0, Visual(0));
        for index in 0..self.cells.len() {
            if self.cells[index].phase == 2 {
                continue;
            }
            let generation = self.cells[index].generation;
            if current.0 != generation {
                current = (generation, self.wave(generation).0, self.living(generation));
            }
            let (_, color, visual) = current;
            let cell = &mut self.cells[index];
            if elapsed == 0 {
                // a cell still growing when the hold was 0 frames shows now
                e.set_visible(cell.slot, true);
            }
            if progress < cell.depart {
                e.set_visual(cell.slot, visual);
                continue;
            }
            let local = ((progress - cell.depart) / FLIGHT).clamp(0.0, 1.0);
            if local >= 1.0 {
                e.set_visible(cell.slot, false);
                cell.phase = 2;
                if let Some(target) = cell.target {
                    let glyph = &mut self.text[target as usize];
                    glyph.spark_until = glyph.spark_until.max(self.frame + SPARK);
                }
                continue;
            }
            if cell.phase == 0 {
                cell.phase = 1;
                cell.color = color;
            }
            // drawn in: slow to leave, fast to land
            let eased = local * local;
            e.set_coordinate(cell.slot, lerp(cell.coord, cell.destination, eased));
            let symbol = if local < 0.45 {
                0
            } else if local < 0.8 {
                1
            } else {
                2
            };
            e.set_visual(cell.slot, self.flying[cell.color][symbol]);
        }
        for glyph in &self.text {
            let since = self.frame - glyph.ignite;
            let visual = if since < 0 {
                glyph.shadow
            } else if since < IGNITE_WHITE || self.frame < glyph.spark_until {
                glyph.white
            } else if since < IGNITE_HOT {
                glyph.hot
            } else {
                glyph.settled
            };
            e.set_visual(glyph.slot, visual);
        }
    }

    /// Progress 1: every cell gone, every glyph settled.
    fn settle(&mut self, e: &mut Engine) {
        for cell in &mut self.cells {
            e.set_visible(cell.slot, false);
            cell.phase = 2;
        }
        if let Some(scan) = &mut self.scan {
            for &slot in &scan.slots {
                e.set_visible(slot, false);
            }
            scan.active = false;
            scan.cleaned = true;
        }
        for glyph in &self.text {
            e.set_coordinate(glyph.slot, glyph.home);
            e.set_visual(glyph.slot, glyph.settled);
            e.set_visible(glyph.slot, true);
        }
    }

    fn finish_flourish(&mut self, e: &mut Engine) {
        if let Some(scan) = &mut self.scan {
            if scan.cleaned {
                return;
            }
            if scan.active {
                for &slot in &scan.slots {
                    e.set_visible(slot, false);
                }
                scan.active = false;
            }
            scan.cleaned = true;
        }
        for glyph in &self.text {
            e.set_visual(glyph.slot, glyph.settled);
        }
    }

    /// Signature Rule-30 CRT refresh scanline flourish during `final-hold-time`.
    fn flourish(&mut self, e: &mut Engine) {
        let hold = self.config.final_hold_time;
        if self.frame >= self.end_frame || hold <= 0 {
            self.finish_flourish(e);
            return;
        }
        let hold_start = self
            .dissolve_start
            .saturating_add(self.config.dissolve_duration);
        let elapsed = (self.frame - hold_start).max(0);
        let u = elapsed as f64 / hold as f64;
        if u < SCAN_START_SHARE {
            return;
        }
        if u >= SCAN_END_SHARE {
            self.finish_flourish(e);
            return;
        }
        let Some(scan) = &mut self.scan else {
            return;
        };
        let s = (u - SCAN_START_SHARE) / (SCAN_END_SHARE - SCAN_START_SHARE);
        let head_f = s * (scan.rows + SCAN_TRAIL_ROWS) as f64;
        let head_row = head_f.floor() as i64;
        let frac = head_f - head_row as f64;
        let show_sync = scan.width >= 6;

        for dy in 0..SCAN_TRAIL_ROWS {
            let r = head_row - dy as i64;
            let row_base = dy * scan.width;
            if r < 0 || r >= scan.rows as i64 {
                for cx in 0..scan.width {
                    e.set_visible(scan.slots[row_base + cx], false);
                }
                continue;
            }
            let ru = r as usize;
            let y = scan.top - r;
            let bit_base = ru * scan.width;
            for cx in 0..scan.width {
                let slot = scan.slots[row_base + cx];
                if scan.occupied[bit_base + cx] {
                    e.set_visible(slot, false);
                    continue;
                }
                let coord = Coord::new(scan.left + cx as i64, y);
                if show_sync && (cx == 0 || cx + 1 == scan.width) {
                    if dy < 3 {
                        let vis = if cx == 0 {
                            scan.sync_left[dy]
                        } else {
                            scan.sync_right[dy]
                        };
                        e.set_coordinate(slot, coord);
                        e.set_visual(slot, vis);
                        e.set_visible(slot, true);
                    } else {
                        e.set_visible(slot, false);
                    }
                } else if scan.bits[bit_base + cx] {
                    let vis = match dy {
                        0 => {
                            if frac < 0.5 {
                                scan.beam_on_hi
                            } else {
                                scan.beam_on_lo
                            }
                        }
                        1 => scan.trail[0],
                        2 => scan.trail[1],
                        _ => scan.trail[2],
                    };
                    e.set_coordinate(slot, coord);
                    e.set_visual(slot, vis);
                    e.set_visible(slot, true);
                } else if dy == 0 {
                    e.set_coordinate(slot, coord);
                    e.set_visual(slot, scan.beam_off);
                    e.set_visible(slot, true);
                } else {
                    e.set_visible(slot, false);
                }
            }
        }
        scan.active = true;
        scan.cleaned = false;

        let scan_top = scan.top;
        let scan_left = scan.left;
        let scan_width = scan.width;
        let scan_rows = scan.rows as i64;
        for glyph in &self.text {
            let r = scan_top - glyph.home.row;
            let dy = head_row - r;
            let vis = if r >= 0 && r < scan_rows && (0..=2).contains(&dy) {
                let cx = glyph.home.column - scan_left;
                let bit = cx >= 0
                    && (cx as usize) < scan_width
                    && scan.bits[r as usize * scan_width + cx as usize];
                match dy {
                    0 => {
                        if bit {
                            glyph.crt_beam_on
                        } else {
                            glyph.hot
                        }
                    }
                    1 => {
                        if bit {
                            glyph.crt_wake_bright
                        } else {
                            glyph.crt_wake_cool
                        }
                    }
                    _ => {
                        if bit {
                            glyph.crt_wake_cool
                        } else {
                            glyph.settled
                        }
                    }
                }
            } else {
                glyph.settled
            };
            e.set_visual(glyph.slot, vis);
        }
    }
}

/// Row-indexed points for nearest-point queries under the metric
/// dx^2 + weight * dy^2. Rows are canvas rows counted from the top; each row
/// holds its points' (column, rank) sorted by column, where rank is the
/// point's place in insertion order (ties go to the lower rank).
struct Rows {
    rows: Vec<Vec<(i64, u32)>>,
    top: i64,
    weight: i64,
}

impl Rows {
    fn new(top: i64, height: usize, weight: i64) -> Self {
        Rows {
            rows: vec![Vec::new(); height],
            top,
            weight,
        }
    }

    fn push(&mut self, coord: Coord, rank: u32) {
        let row = self.top - coord.row;
        if let Some(points) = usize::try_from(row).ok().and_then(|r| self.rows.get_mut(r)) {
            points.push((coord.column, rank));
        }
    }

    fn sort(&mut self) {
        for points in &mut self.rows {
            points.sort_unstable();
        }
    }

    /// The (cost, rank) of the point nearest `coord`, ties to the lower
    /// rank. Rows are visited outward from the query's; the search stops
    /// once a row's vertical cost alone exceeds the best found.
    fn nearest(&self, coord: Coord) -> Option<(i64, u32)> {
        let height = self.rows.len() as i64;
        if height == 0 {
            return None;
        }
        let query = self.top - coord.row;
        let start = query.clamp(0, height - 1);
        let cost_y = |r: i64| {
            let dy = r - query;
            dy.saturating_mul(dy).saturating_mul(self.weight)
        };
        let mut best: Option<(i64, u32)> = None;
        for d in 0..height {
            let (up, down) = (start - d, start + d);
            let rows = [
                (up >= 0).then_some(up),
                (d > 0 && down < height).then_some(down),
            ];
            let Some(bound) = rows.iter().flatten().map(|&r| cost_y(r)).min() else {
                break;
            };
            if best.is_some_and(|(b, _)| bound > b) {
                break;
            }
            for r in rows.into_iter().flatten() {
                let points = &self.rows[r as usize];
                // the nearest column left of `coord` and the nearest at or
                // right of it
                let at = points.partition_point(|&(c, _)| c < coord.column);
                for i in [at.wrapping_sub(1), at] {
                    if let Some(&(column, rank)) = points.get(i) {
                        let dx = column - coord.column;
                        let cost = dx.saturating_mul(dx).saturating_add(cost_y(r));
                        if best.is_none_or(|b| (cost, rank) < b) {
                            best = Some((cost, rank));
                        }
                    }
                }
            }
        }
        best
    }
}

impl Hooks for Automata {}

impl Effect for Automata {
    fn build(&mut self, e: &mut Engine) -> Result<(), EngineError> {
        let config = self.config.clone();
        let canvas = e.canvas.clone();
        let width = (canvas.right - canvas.left + 1).max(1) as usize;
        let height = (canvas.top - canvas.bottom + 1).max(1) as usize;
        let dynamic = e.existing_color_handling() == ExistingColorHandling::Dynamic;
        let white = Color::from_hex("ffffff").expect("white");
        let black = Color::from_hex("000000").expect("black");
        let crt_primary = config.cell_colors[0];
        let crt_mid = config.cell_colors[config.cell_colors.len() / 2];
        let crt_tail = config.cell_colors[config.cell_colors.len() - 1];
        let crt_bloom_bg = toward(black, crt_primary, 0.22);
        let crt_wake_bg = toward(black, crt_mid, 0.14);

        // the text: in shadow until the automaton resolves into it
        let mapping = Gradient::new(
            &config.final_gradient_stops,
            &config.final_gradient_steps,
            false,
            false,
        )
        .and_then(|gradient| {
            gradient.build_coordinate_color_mapping(
                canvas.text_bottom,
                canvas.text_top,
                canvas.text_left,
                canvas.text_right,
                config.final_gradient_direction,
            )
        })
        .ok();
        let fallback = config.final_gradient_stops[0];
        let slots = e.get_characters(
            CharacterFilter::default(),
            CharacterSort::TopToBottomLeftToRight,
        );
        for &slot in &slots {
            let home = e.input_coord(slot);
            let sym = e.input_sym(slot);
            let fg = mapping
                .as_ref()
                .and_then(|m| m.get(&home).copied())
                .unwrap_or(fallback);
            let colors = if dynamic {
                ColorPair::new(e.input_fg(slot), e.input_bg(slot))
            } else {
                ColorPair::new(Some(fg), None)
            };
            let shadow = appearance(
                e,
                slot,
                sym,
                ColorPair::new(Some(config.shadow_color), None),
            );
            let base_fg = colors.fg_color.unwrap_or(fg);
            let hot_fg = toward(base_fg, white, 0.55);
            let hot = appearance(e, slot, sym, ColorPair::new(Some(hot_fg), colors.bg_color));
            let settled = appearance(e, slot, sym, colors);
            let flash = appearance(e, slot, sym, ColorPair::new(Some(white), colors.bg_color));
            let beam_bg = colors.bg_color.or(Some(crt_bloom_bg));
            let wake_bg = colors.bg_color.or(Some(crt_wake_bg));
            let crt_beam_on = appearance(e, slot, sym, ColorPair::new(Some(white), beam_bg));
            let wake_bright_fg = toward(base_fg, toward(crt_primary, white, 0.45), 0.7);
            let crt_wake_bright =
                appearance(e, slot, sym, ColorPair::new(Some(wake_bright_fg), wake_bg));
            let wake_cool_fg = toward(base_fg, crt_mid, 0.45);
            let crt_wake_cool = appearance(
                e,
                slot,
                sym,
                ColorPair::new(Some(wake_cool_fg), colors.bg_color),
            );
            e.set_visual(slot, shadow);
            e.set_visible(slot, true);
            self.text.push(Glyph {
                slot,
                home,
                ignite: 0,
                spark_until: 0,
                shadow,
                hot,
                settled,
                white: flash,
                crt_beam_on,
                crt_wake_bright,
                crt_wake_cool,
            });
        }

        // the visuals: the looped cell palette, cool, hot and white
        let palette = Gradient::new(&config.cell_colors, &[WAVE_STEPS], false, true)
            .map(|g| g.spectrum)
            .unwrap_or_else(|_| config.cell_colors.clone());
        for symbol in &config.cell_symbols {
            let cool = palette.iter().map(|&c| plain(e, symbol, c)).collect();
            let hot = palette
                .iter()
                .map(|&c| plain(e, symbol, toward(c, white, 0.6)))
                .collect();
            self.cool.push(cool);
            self.hot.push(hot);
            self.white.push(plain(e, symbol, white));
        }
        self.flying = palette
            .iter()
            .map(|&c| {
                [
                    plain(e, FLIGHT_SYMBOLS[0], c),
                    plain(e, FLIGHT_SYMBOLS[1], toward(c, white, 0.4)),
                    plain(e, FLIGHT_SYMBOLS[2], toward(c, white, 0.8)),
                ]
            })
            .collect();

        // the automaton: one generation per canvas row, top down
        let mut generation = vec![false; width];
        let mut next = vec![false; width];
        let seeds = config.seed_cells;
        for seed in 0..seeds.min(width as i64) {
            let at = ((seed + 1) as f64 / (seeds + 1) as f64 * (width - 1) as f64).round() as usize;
            generation[at.min(width - 1)] = true;
        }
        if seeds > width as i64 {
            generation.fill(true);
        }
        let mut cell_rows = Rows::new(canvas.top, height, 4);
        let first_symbol = e.sym(&config.cell_symbols[0]);
        for row in 0..height {
            for (column, _) in generation.iter().enumerate().filter(|(_, &alive)| alive) {
                let coord = Coord::new(canvas.left + column as i64, canvas.top - row as i64);
                let slot = e.add_character_sym(first_symbol, coord);
                e.set_layer(slot, 3);
                cell_rows.push(coord, self.cells.len() as u32);
                self.cells.push(Cell {
                    slot,
                    coord,
                    generation: row as i64,
                    depart: 0.0,
                    destination: coord,
                    target: None,
                    color: 0,
                    phase: 0,
                });
            }
            Self::next_generation(config.rule, &generation, &mut next);
            std::mem::swap(&mut generation, &mut next);
        }
        cell_rows.sort();

        // each cell is drawn into its nearest glyph, the cells nearest the
        // text leaving first
        let space = e.sym(" ");
        let mut glyph_rows = Rows::new(canvas.top, height, 4);
        for (rank, glyph) in self.text.iter().enumerate() {
            if e.input_sym(glyph.slot) != space {
                glyph_rows.push(glyph.home, rank as u32);
            }
        }
        glyph_rows.sort();
        let reach: Vec<f64> = self
            .cells
            .iter()
            .map(|cell| glyph_rows.nearest(cell.coord).map_or(0.0, |(cost, _)| (cost as f64).sqrt()))
            .collect();
        let far = reach.iter().copied().fold(0.0, f64::max);
        for (cell, &distance) in self.cells.iter_mut().zip(&reach) {
            let share = if far > 0.0 { distance / far } else { 0.0 };
            cell.depart = share * DEPART_SPREAD + e.rng.random() * DEPART_JITTER;
            if let Some((_, target)) = glyph_rows.nearest(cell.coord) {
                cell.target = Some(target);
                cell.destination = self.text[target as usize].home;
            }
        }

        // the text ignites outward from where the lattice touches it, and no
        // later than its first cell lands
        let duration = config.dissolve_duration as f64;
        let mut ignite: Vec<f64> = self
            .text
            .iter()
            .map(|glyph| cell_rows.nearest(glyph.home).map_or(0.0, |(cost, _)| (cost as f64).sqrt()))
            .collect();
        let far = ignite.iter().copied().fold(0.0, f64::max);
        for share in &mut ignite {
            *share = if far > 0.0 { *share / far } else { 0.0 } * IGNITE_SPREAD
                + e.rng.random() * IGNITE_JITTER;
        }
        for cell in &self.cells {
            if let Some(target) = cell.target {
                let landing = &mut ignite[target as usize];
                *landing = landing.min(cell.depart + FLIGHT);
            }
        }
        let growth_end = (height as i64).saturating_mul(config.generation_time);
        self.dissolve_start = growth_end.saturating_add(config.hold_time);
        for (glyph, share) in self.text.iter_mut().zip(ignite) {
            glyph.ignite = self.dissolve_start.saturating_add((share * duration).round() as i64);
        }
        self.end_frame = self
            .dissolve_start
            .saturating_add(config.dissolve_duration)
            .saturating_add(config.final_hold_time);

        // Precompute the Rule-30 CRT refresh scanline scoped to the text bounds
        // plus small margins scaled to the canvas.
        if config.final_hold_time > 0 && !self.text.is_empty() {
            let text_h = (canvas.text_top - canvas.text_bottom + 1).max(1);
            let side_margin = (width as i64 / 28).clamp(2, 14);
            let vert_margin = ((height as i64 - text_h) / 4).clamp(0, 3);
            let scan_left = (canvas.text_left - side_margin).max(canvas.left);
            let scan_right = (canvas.text_right + side_margin).min(canvas.right);
            let scan_top = (canvas.text_top + vert_margin).min(canvas.top);
            let scan_bottom = (canvas.text_bottom - vert_margin).max(canvas.bottom);
            let scan_width = (scan_right - scan_left + 1).max(1) as usize;
            let scan_rows = (scan_top - scan_bottom + 1).max(1) as usize;

            let mut cur = vec![false; scan_width];
            let mut nxt = vec![false; scan_width];
            let spacing = (scan_width / 9).clamp(6, 12);
            let offset = (e.rng.random() * spacing as f64) as usize;
            let mut idx = offset % scan_width;
            while idx < scan_width {
                cur[idx] = true;
                idx += spacing;
            }
            cur[scan_width / 2] = true;
            for _ in 0..SCAN_WARMUP_GENS {
                Self::next_generation(SCAN_RULE, &cur, &mut nxt);
                std::mem::swap(&mut cur, &mut nxt);
            }
            let mut bits = Vec::with_capacity(scan_rows * scan_width);
            for _ in 0..scan_rows {
                bits.extend_from_slice(&cur);
                Self::next_generation(SCAN_RULE, &cur, &mut nxt);
                std::mem::swap(&mut cur, &mut nxt);
            }

            let mut occupied = vec![false; scan_rows * scan_width];
            for glyph in &self.text {
                if e.input_sym(glyph.slot) == space {
                    continue;
                }
                let r = scan_top - glyph.home.row;
                let cx = glyph.home.column - scan_left;
                if r >= 0 && (r as usize) < scan_rows && cx >= 0 && (cx as usize) < scan_width {
                    occupied[r as usize * scan_width + cx as usize] = true;
                }
            }

            let scan_sym = e.sym("▀");
            let origin = Coord::new(scan_left, scan_top);
            let mut scan_slots = Vec::with_capacity(SCAN_TRAIL_ROWS * scan_width);
            for _ in 0..(SCAN_TRAIL_ROWS * scan_width) {
                let slot = e.add_character_sym(scan_sym, origin);
                e.set_layer(slot, 2);
                e.set_visible(slot, false);
                scan_slots.push(slot);
            }

            let beam_on_hi = plain(e, "▀", toward(crt_primary, white, 0.85));
            let beam_on_lo = plain(e, "▄", toward(crt_primary, white, 0.85));
            let beam_off = plain(e, "─", toward(black, crt_primary, 0.24));
            let trail = [
                plain(e, "▓", toward(crt_primary, white, 0.25)),
                plain(e, "▒", crt_mid),
                plain(e, "░", toward(crt_tail, black, 0.45)),
            ];
            let sync_left = [
                plain(e, "▕", white),
                plain(e, "▕", crt_primary),
                plain(e, "▕", crt_mid),
            ];
            let sync_right = [
                plain(e, "▏", white),
                plain(e, "▏", crt_primary),
                plain(e, "▏", crt_mid),
            ];

            self.scan = Some(Scanline {
                left: scan_left,
                top: scan_top,
                width: scan_width,
                rows: scan_rows,
                bits,
                occupied,
                slots: scan_slots,
                beam_on_hi,
                beam_on_lo,
                beam_off,
                trail,
                sync_left,
                sync_right,
                active: false,
                cleaned: true,
            });
        }

        self.frame = 0;
        Ok(())
    }

    fn next_frame(&mut self, e: &mut Engine) -> bool {
        if self.frame > self.end_frame {
            return false;
        }
        if self.frame < self.dissolve_start {
            self.live(e);
        } else if self.frame - self.dissolve_start < self.config.dissolve_duration {
            self.dissolve(e);
        } else {
            if self.frame - self.dissolve_start == self.config.dissolve_duration {
                self.settle(e);
            }
            self.flourish(e);
        }
        self.frame += 1;
        true
    }
}

#[cfg(test)]
mod tests {
    use std::hash::{DefaultHasher, Hash, Hasher};

    use clap::Parser;

    use crate::cli::Cli;
    use crate::engine::ctx::Clock;
    use crate::fx::run::Effect;
    use crate::fx::{effects, Engine, CF_INPUT};
    use crate::utils::rng::Rng;

    /// Outcome of a run to completion.
    pub struct Run {
        pub frames: u64,
        pub engine: Engine,
        /// The last frame, ANSI stripped.
        pub last: String,
        /// A hash of every 7th frame's bytes: the run's course.
        pub trace: u64,
    }

    pub fn strip_ansi(bytes: &[u8]) -> String {
        let text = String::from_utf8_lossy(bytes);
        let mut out = String::new();
        let mut chars = text.chars().peekable();
        while let Some(c) = chars.next() {
            if c == '\x1b' {
                if chars.peek() == Some(&'[') {
                    chars.next();
                    for c in chars.by_ref() {
                        if c.is_ascii_alphabetic() {
                            break;
                        }
                    }
                }
                continue;
            }
            out.push(c);
        }
        out
    }

    fn frame_text(e: &Engine) -> String {
        let mut parts = Vec::new();
        e.renderer().frame_parts(b"", b"", &mut parts);
        let bytes: Vec<u8> = parts.iter().flat_map(|p| p.iter().copied()).collect();
        strip_ansi(&bytes)
    }

    /// The engine and effect for a run; None when the engine refuses the
    /// input (whitespace only: ttfx exits with "NO INPUT." before this).
    fn engine(input: &str, args: &[String]) -> Option<(Engine, Box<dyn Effect>)> {
        let mut argv = vec![
            "ttfx".to_string(),
            "--ignore-terminal-dimensions".to_string(),
        ];
        argv.extend(args.iter().cloned());
        let cli = Cli::try_parse_from(&argv).expect("arguments parse");
        let seed = cli.seed.unwrap_or(1);
        let effect = effects::build(cli.effect.as_ref().expect("an effect")).expect("fx effect");
        let e = Engine::new(
            input,
            cli.terminal_config(),
            Rng::seeded(seed),
            Clock::virtual_with_frame_rate(60),
        );
        match e {
            Ok(e) => Some((e, effect)),
            Err(err) => {
                assert!(input.trim().is_empty(), "engine refused {input:?}: {err}");
                None
            }
        }
    }

    /// Run `args` (global options, the effect name, its options) on `input`
    /// to completion, at most `cap` frames. None when the engine refuses the
    /// input.
    pub fn try_run(input: &str, args: &[&str], cap: u64) -> Option<Run> {
        let args: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        let (mut e, mut effect) = engine(input, &args)?;
        effect.build(&mut e).expect("build");
        let mut frames = 0;
        let mut trace = DefaultHasher::new();
        while effect.next_frame(&mut e) {
            frames += 1;
            assert!(frames <= cap, "no end after {cap} frames");
            if frames % 7 == 0 {
                e.render_here();
                let mut parts = Vec::new();
                e.renderer().frame_parts(b"", b"", &mut parts);
                for part in &parts {
                    part.hash(&mut trace);
                }
            }
        }
        e.render_here();
        let last = frame_text(&e);
        Some(Run {
            frames,
            engine: e,
            last,
            trace: trace.finish(),
        })
    }

    pub fn run(input: &str, args: &[&str], cap: u64) -> Run {
        try_run(input, args, cap).expect("the engine takes this input")
    }

    /// The input as the canvas shows it settled: every input character home.
    pub fn settled_text(input: &str, args: &[&str]) -> String {
        let args: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        let (mut e, _) = engine(input, &args).expect("engine");
        for slot in e.input_chars.clone() {
            e.set_visible(slot, true);
        }
        e.render_here();
        frame_text(&e)
    }

    /// The run ended settled: input characters home, visible, showing their
    /// symbol; every added character hidden; the frame reads as the input.
    pub fn assert_settled(run: &Run, input: &str, args: &[&str]) {
        let e = &run.engine;
        for slot in 0..e.char_count() as u32 {
            if e.ch.flags[slot as usize] & CF_INPUT != 0 {
                assert_eq!(e.coord(slot), e.input_coord(slot), "slot {slot} not home");
                assert!(e.is_visible(slot), "slot {slot} hidden");
                let info = e.visual_info(e.current_visual(slot));
                assert_eq!(info.sym, e.input_sym(slot), "slot {slot} symbol");
            } else if !e.is_fill(slot) {
                assert!(!e.is_visible(slot), "added slot {slot} still visible");
            }
        }
        assert_eq!(
            run.last,
            settled_text(input, args),
            "last frame differs from the input"
        );
    }

    /// Edge inputs every community effect must survive.
    pub const EDGE_INPUTS: &[&str] = &[
        "OMARCHY\nhello world\n",
        "x",
        " ",
        "\n\n",
        "wide: 漢字テスト 🙂 ok\n",
        "\x1b[38;2;255;0;0mred\x1b[0m plain \x1b[1;32mbold green\x1b[0m\n",
    ];

    pub fn long_line() -> String {
        "the quick brown fox ".repeat(40)
    }

    const CAP: u64 = 50_000;

    fn args<'a>(globals: &[&'a str], effect: &[&'a str]) -> Vec<&'a str> {
        let mut all = globals.to_vec();
        all.push("automata");
        all.extend_from_slice(effect);
        all
    }

    #[test]
    fn settles_on_edge_inputs() {
        let long = long_line();
        let mut inputs: Vec<&str> = EDGE_INPUTS.to_vec();
        inputs.push(&long);
        for canvas in [
            &["--seed", "3"][..],
            &[
                "--seed",
                "3",
                "--canvas-width",
                "10",
                "--canvas-height",
                "3",
            ],
            &["--seed", "3", "--canvas-width", "0", "--canvas-height", "0"],
            &["--seed", "3", "--canvas-width", "1", "--canvas-height", "1"],
            &[
                "--seed",
                "3",
                "--canvas-width",
                "220",
                "--canvas-height",
                "60",
            ],
        ] {
            for input in &inputs {
                for rule in ["90", "0", "255", "30"] {
                    let a = args(
                        canvas,
                        &[
                            "--rule",
                            rule,
                            "--generation-time",
                            "1",
                            "--dissolve-duration",
                            "40",
                        ],
                    );
                    if let Some(run) = try_run(input, &a, CAP) {
                        assert_settled(&run, input, &a);
                    }
                }
            }
        }
    }

    #[test]
    fn default_run_settles() {
        let input = "OMARCHY\nhello world\n";
        let a = args(&["--seed", "1"], &[]);
        let run = run(input, &a, CAP);
        assert_settled(&run, input, &a);
    }

    #[test]
    fn many_seed_cells_and_zero_holds() {
        let input = "OMARCHY\nhello world\n";
        let a = args(
            &[
                "--seed",
                "1",
                "--canvas-width",
                "30",
                "--canvas-height",
                "8",
            ],
            &[
                "--seed-cells",
                "1000",
                "--hold-time",
                "0",
                "--final-hold-time",
                "0",
                "--dissolve-duration",
                "1",
            ],
        );
        let run = run(input, &a, CAP);
        assert_settled(&run, input, &a);
    }

    #[test]
    fn deterministic_for_a_seed() {
        let input = "OMARCHY\nhello world\n";
        let a = args(&["--seed", "9"], &["--generation-time", "1"]);
        let one = run(input, &a, CAP);
        let two = run(input, &a, CAP);
        assert_eq!(one.frames, two.frames);
        assert_eq!(one.last, two.last);
        assert_eq!(one.trace, two.trace, "same seed, different course");
        let mut other = a.clone();
        other[1] = "10";
        assert_ne!(
            run(input, &other, CAP).trace,
            one.trace,
            "the seed changes nothing"
        );
    }

    #[test]
    fn dynamic_keeps_input_colors() {
        let input = EDGE_INPUTS[5];
        let a = args(
            &["--seed", "2", "--existing-color-handling", "dynamic"],
            &[],
        );
        let run = run(input, &a, CAP);
        assert_settled(&run, input, &a);
        let e = &run.engine;
        for &slot in &e.input_chars {
            let info = e.visual_info(e.current_visual(slot));
            assert_eq!(
                info.fg,
                e.input_fg(slot),
                "slot {slot} lost its input color"
            );
        }
    }

    #[test]
    fn every_timing_option_moves_the_end() {
        let input = "OMARCHY\nhello world\n";
        let base = run(input, &args(&["--seed", "4"], &[]), CAP).frames;
        for (option, value) in [
            ("--generation-time", "7"),
            ("--hold-time", "10"),
            ("--dissolve-duration", "90"),
            ("--final-hold-time", "5"),
        ] {
            let frames = run(input, &args(&["--seed", "4"], &[option, value]), CAP).frames;
            assert_ne!(
                frames, base,
                "{option} {value} left the run length at {base}"
            );
        }
    }

    #[test]
    fn big_canvas_is_fast() {
        let input = std::fs::read_to_string("/usr/share/omarchy/logo.txt")
            .unwrap_or_else(|_| "OMARCHY\nhello world\n".to_string());
        for rule in ["90", "255"] {
            let a = args(
                &["--seed", "5", "--canvas-width", "300", "--canvas-height", "90"],
                &["--rule", rule],
            );
            let start = std::time::Instant::now();
            let run = run(&input, &a, CAP);
            let took = start.elapsed();
            assert_settled(&run, &input, &a);
            eprintln!("rule {rule}: {} frames in {took:?}", run.frames);
            if rule == "90" {
                // the default; rule 255 fills the canvas and is only checked to settle
                assert!(took.as_secs_f64() < 1.0, "rule {rule} took {took:?}");
            }
        }
    }
}
