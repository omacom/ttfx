//! fireflies: fireflies drift in from the edges, blink, gather in a swarm
//! around the text, then land cluster by cluster, lighting their characters
//! up; a few lantern fireflies stay to orbit the finished text, warming the
//! letters they pass before drifting into the night.
//!
//! Original effect by Tushar Malpani (@tusharmalpani20), https://github.com/tusharmalpani20/tte-community-effects, MIT.
//! (Python TerminalTextEffects plugin, ChrisBuilds/terminaltexteffects#76.)
//!
//! Every input character is a firefly. Characters are bucketed into 4x2
//! clusters (shuffled); a firefly starts on a random perimeter cell, enters
//! on a short curve, wanders `--wander-cycles` curved waypoints around its
//! cluster's centre, then hovers there in slow loops, blinking. Once most of
//! the swarm has gathered the landing cascade starts: clusters are released
//! one after another over at most `--landing-duration` frames (9 frames
//! apart, as in the original, until that budget is spread thin), each
//! firefly optionally orbits the centre, then approaches its cell with a
//! small overshoot. A landing scene flashes the symbol and cools into the
//! final color, and an ember sometimes rises off the top of the letter. A
//! handful of atmospheric fireflies (`--auxiliary-count`, at most 12, fewer
//! on small canvases) roam the night until the cascade is out and then leave
//! through an edge. Finally, two or three lantern fireflies linger to weave
//! smooth figure-eight and halo orbits around the finished logo, trailing
//! faint golden sparks in empty space and warming every letter they pass
//! with a soft amber afterglow before drifting away into the dark.
//!
//! Differences from the original, for a fullscreen screensaver: the run
//! length no longer grows with the text (the cascade and the emergence are
//! spread over a fixed budget), and the long flights scale their speed with
//! the canvas so a big terminal takes about as long as a small one (far
//! starters also hurry, so the swarm gathers together instead of trickling
//! in; both stay proportional to `--movement-speed`); curve
//! bulges scale with the hop instead of the canvas, so the final approach
//! stays tight; waiting fireflies hover instead of freezing; the blink is a
//! slow glow (dim, rise, flash, fall) with the symbol following brightness.
//!
//! Path and scene completions arrive as callbacks; fireflies waiting are
//! re-added to the active set each frame.

use clap::Args;

use crate::cli::parse_color;
use crate::effects::common::{
    parse_gradient_direction, parse_gradient_steps, parse_non_negative_int, parse_positive_float,
    parse_positive_int, parse_symbol,
};
use crate::engine::animation::{Animation, ExistingColorHandling, SyncMetric};
use crate::engine::error::EngineError;
use crate::engine::terminal::{CharacterFilter, CharacterSort};
use crate::fx::events::{Action, Caller, Event};
use crate::fx::particles::{ParticlePool, ParticleReset};
use crate::fx::run::Effect;
use crate::fx::{Engine, Hooks, Name, Sym};
use crate::utils::easing::Easing;
use crate::utils::geometry::{find_length_of_bezier_curve, Coord};
use crate::utils::graphics::{Color, ColorPair, Gradient, GradientDirection};
use crate::utils::pycompat::{floor_div, round_half_even};

#[derive(Args, Debug, Clone)]
pub struct FirefliesConfig {
    /// Colors used from dimmest to brightest while fireflies blink.
    #[arg(long = "firefly-colors", num_args = 1.., value_parser = parse_color,
          default_values = ["6b5c20", "d4a72c", "fff2a1"])]
    pub firefly_colors: Vec<Color>,

    /// One-cell symbols used in sequence while fireflies blink.
    #[arg(long = "firefly-symbols", num_args = 1.., value_parser = parse_symbol,
          default_values = [".", "*", "o", "*"])]
    pub firefly_symbols: Vec<String>,

    /// Base movement speed for fireflies. Individual speeds vary around this value.
    #[arg(long = "movement-speed", default_value_t = 0.18, value_parser = parse_positive_float)]
    pub movement_speed: f64,

    /// Maximum number of wandering waypoints before a firefly gathers near the text.
    #[arg(long = "wander-cycles", default_value_t = 3, value_parser = parse_positive_int)]
    pub wander_cycles: i64,

    /// Maximum number of atmospheric fireflies. Tiny canvases automatically use fewer.
    #[arg(long = "auxiliary-count", default_value_t = 6, value_parser = parse_non_negative_int)]
    pub auxiliary_count: i64,

    /// Frames over which the clusters are released to land. Fewer than 60
    /// clusters land 1/60th of this apart (9 frames by default, like the
    /// original); more share the whole budget, so big text does not run long.
    #[arg(long = "landing-duration", default_value_t = 540, value_parser = parse_positive_int)]
    pub landing_duration: i64,

    /// Space separated, unquoted, list of colors for the final color gradient.
    #[arg(long = "final-gradient-stops", num_args = 1.., value_parser = parse_color,
          default_values = ["3f4f24", "d6a928", "ffe680"])]
    pub final_gradient_stops: Vec<Color>,

    /// Number of gradient steps to use.
    #[arg(long = "final-gradient-steps", num_args = 1.., value_parser = parse_gradient_steps,
          default_values = ["12"])]
    pub final_gradient_steps: Vec<i64>,

    /// Direction of the final gradient.
    #[arg(long = "final-gradient-direction", default_value = "horizontal",
          value_parser = parse_gradient_direction)]
    pub final_gradient_direction: GradientDirection,
}

const CLUSTER_WIDTH: i64 = 4;
const CLUSTER_HEIGHT: i64 = 2;
/// Up to this many clusters keep the original per-cluster spacing; more
/// share the fixed budgets.
const SPREAD_CLUSTERS: f64 = 60.0;
/// Frames over which fireflies emerge (2 per cluster in the original).
const EMERGE_FRAMES: f64 = 120.0;
/// The canvas the original's speeds look right on.
const REFERENCE_AREA: f64 = 96.0 * 24.0;
/// The share of the swarm that must be gathered before the cascade starts,
/// and the beat it hovers before the first landing.
const GATHERED_SHARE: f64 = 0.6;
const HOVER_BEAT: i64 = 30;
/// The longest a wander takes per cycle at the default movement speed.
const WANDER_FRAMES: f64 = 140.0;
const DEFAULT_SPEED: f64 = 0.18;
/// The signature lantern flourish: entry swoop, orbital dance, and night-sky drift-out.
const FLOURISH_ENTER: i64 = 55;
const FLOURISH_ORBIT: i64 = 340;
const FLOURISH_EXIT: i64 = 105;
/// Quantized afterglow steps per letter (0 = exact final color, 1..=HEAT_LEVELS = warm glow).
const HEAT_LEVELS: u8 = 12;
/// Per-frame cooling rate for warmed letters (~42 frames / 0.35s velvety afterglow).
const HEAT_DECAY: f32 = 0.024;
/// Rising embers alive at once.
const EMBERS: usize = 24;

// callback ids (the arg is the firefly index)
const FINISH_ENTRY: u32 = 0;
const FINISH_WANDER: u32 = 1;
const FINISH_ORBIT: u32 = 2;
const LAND: u32 = 3;
const SETTLE: u32 = 4;
/// An atmospheric helper finished its departure: back to the pool.
const RECLAIM: u32 = 5;
/// An ember finished: back to its pool.
const RECLAIM_EMBER: u32 = 6;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum State {
    Dormant,
    Entering,
    Wandering,
    Gathering,
    Orbiting,
    Approaching,
    Illuminating,
    Settled,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    Reveal,
    Flourish,
    Complete,
}

#[derive(Clone, Copy)]
enum OrbitKind {
    FigureEight,
    OuterHalo,
    CounterRibbon,
}

struct Lantern {
    slot: u32,
    trail: [u32; 4],
    history: Vec<Coord>,
    kind: OrbitKind,
    phase: f64,
    pulse_freq: f64,
    pulse_phase: f64,
    exit_dx: f64,
    exit_dy: f64,
    last_x: f64,
    last_y: f64,
}

struct Firefly {
    slot: u32,
    target: Coord,
    activation_frame: i64,
    /// Frames after the cascade start; `release_frame` is set when it starts.
    release_offset: i64,
    release_frame: i64,
    has_orbit: bool,
    state: State,
}

/// Interned path and scene names.
struct Names {
    enter: Name,
    wander: Name,
    hover: Name,
    rise: Name,
    orbit: Name,
    approach: Name,
    atmosphere: Name,
    depart: Name,
    blink: Name,
    landing: Name,
    halo: Name,
}

pub struct Fireflies {
    config: FirefliesConfig,
    names: Option<Names>,
    fireflies: Vec<Firefly>,
    final_colors: Vec<ColorPair>,
    settled: usize,
    gathered: usize,
    /// The frame the landing cascade starts; None while the swarm gathers.
    cascade_start: Option<i64>,
    last_release_offset: i64,
    frame_count: i64,
    phase: Phase,
    lanterns: Vec<Lantern>,
    heat: Vec<f32>,
    heat_level: Vec<u8>,
    flourish_tick: i64,
    flourish_enter: i64,
    flourish_orbit: i64,
    flourish_exit: i64,
    text_center: (f64, f64),
    orbit_rx: f64,
    orbit_ry: f64,
    glow_rx: f64,
    glow_ry: f64,
    firefly_syms: Vec<Sym>,
    wake_syms: [Sym; 2],
    palette: [Color; 3],
    perimeter: Vec<Coord>,
    /// Long flights move this much faster on canvases bigger than 96x24.
    speed_scale: f64,
    pool: Option<ParticlePool>,
    embers: Option<ParticlePool>,
    text_cells: std::collections::HashSet<Coord, crate::fx::FxBuild>,
    aux_activation_frames: Vec<i64>,
    aux_next: usize,
    aux_departed: bool,
    halo_sym: Sym,
}

impl Fireflies {
    pub fn new(config: FirefliesConfig) -> Self {
        Fireflies {
            config,
            names: None,
            fireflies: Vec::new(),
            final_colors: Vec::new(),
            settled: 0,
            gathered: 0,
            cascade_start: None,
            last_release_offset: 0,
            frame_count: 0,
            phase: Phase::Complete,
            lanterns: Vec::new(),
            heat: Vec::new(),
            heat_level: Vec::new(),
            flourish_tick: 0,
            flourish_enter: FLOURISH_ENTER,
            flourish_orbit: FLOURISH_ORBIT,
            flourish_exit: FLOURISH_EXIT,
            text_center: (1.0, 1.0),
            orbit_rx: 1.0,
            orbit_ry: 1.0,
            glow_rx: 5.0,
            glow_ry: 2.5,
            firefly_syms: Vec::new(),
            wake_syms: [Sym(0), Sym(0)],
            palette: [Color::from_rgb(0, 0, 0); 3],
            perimeter: Vec::new(),
            speed_scale: 1.0,
            pool: None,
            embers: None,
            text_cells: Default::default(),
            aux_activation_frames: Vec::new(),
            aux_next: 0,
            aux_departed: false,
            halo_sym: Sym(0),
        }
    }

    fn names(&self) -> &Names {
        self.names.as_ref().expect("fireflies: not built")
    }
}

fn other(message: String) -> EngineError {
    EngineError::Other(message)
}

fn clamp_coord(e: &Engine, column: i64, row: i64) -> Coord {
    let c = &e.canvas;
    Coord::new(
        column.max(c.left).min(c.right.max(c.left)),
        row.max(c.bottom).min(c.top.max(c.bottom)),
    )
}

/// A gently offset, in-canvas control point between two coordinates. The
/// bulge is at most a sixth of the canvas (the original's) and at most half
/// the hop, so short hops stay short on a big canvas.
fn curve_control(e: &mut Engine, start: Coord, end: Coord) -> Coord {
    let mid_column = round_half_even((start.column + end.column) as f64 / 2.0);
    let mid_row = round_half_even((start.row + end.row) as f64 / 2.0);
    // rows are about twice as tall as columns are wide
    let hop = (end.column - start.column)
        .abs()
        .max(2 * (end.row - start.row).abs());
    let horizontal = floor_div(e.canvas.width, 6).min(hop / 2).max(1);
    let vertical = floor_div(e.canvas.height, 6).min(hop / 4).max(1);
    let dc = e.rng.randint(-horizontal, horizontal);
    let dr = e.rng.randint(-vertical, vertical);
    clamp_coord(e, mid_column + dc, mid_row + dr)
}

/// Every unique perimeter coordinate, sorted by (row, column).
fn perimeter_coords(e: &Engine) -> Vec<Coord> {
    let c = &e.canvas;
    let mut coords = Vec::new();
    for row in c.bottom..=c.top {
        for column in c.left..=c.right {
            if row == c.bottom || row == c.top || column == c.left || column == c.right {
                coords.push(Coord::new(column, row));
            }
        }
    }
    if coords.is_empty() {
        coords.push(Coord::new(c.left.max(1), c.bottom.max(1)));
    }
    coords
}

fn lerp_color(a: Color, b: Color, t: f64) -> Color {
    let t = t.clamp(0.0, 1.0);
    let (ar, ag, ab) = a.rgb_ints();
    let (br, bg, bb) = b.rgb_ints();
    let mix = |x: u8, y: u8| -> u8 {
        ((x as f64) + ((y as f64) - (x as f64)) * t)
            .round()
            .clamp(0.0, 255.0) as u8
    };
    Color::from_rgb(mix(ar, br), mix(ag, bg), mix(ab, bb))
}

/// Dim, warm and peak colors, even with one configured color.
fn blink_palette(colors: &[Color]) -> Result<[Color; 3], String> {
    if colors.len() == 1 {
        let base = colors[0];
        return Ok([
            Animation::adjust_color_brightness(&base, 0.35),
            Animation::adjust_color_brightness(&base, 0.7),
            base,
        ]);
    }
    let spectrum = Gradient::with_steps(colors, 3, false)?.spectrum;
    Ok([
        spectrum[0],
        spectrum[spectrum.len() / 2],
        spectrum[spectrum.len() - 1],
    ])
}

fn add_waypoint(e: &mut Engine, path: u32, coord: Coord, control: Coord) -> Result<(), String> {
    e.path_new_waypoint(path, coord, Some(&[control]), Name::NONE)
        .map(|_| ())
}

/// A slow firefly glow: dim for a while, rise, flash, fall. The symbol
/// follows the brightness (dim, warm, peak, warm = symbols 0..4, cycled).
#[allow(clippy::too_many_arguments)]
fn add_glow_scene(
    e: &mut Engine,
    slot: u32,
    name: Name,
    palette: &[Color; 3],
    symbols: &[Sym],
    phase: usize,
    period: i64,
    peak_hold: i64,
) -> Result<(), String> {
    let levels = [
        (palette[0], period * 5),
        (palette[1], period * 2),
        (palette[2], peak_hold * 3),
        (palette[1], period * 2),
    ];
    let scene = e.scene_new(slot, name, true, None, None);
    for k in 0..4 {
        let i = (k + phase) % 4;
        let (color, duration) = levels[i];
        e.add_frame(
            scene,
            symbols[i % symbols.len()],
            duration,
            Some(ColorPair::new(Some(color), None)),
            0,
        )?;
    }
    Ok(())
}

/// The atmospheric helper's reusable blink scene.
fn init_auxiliary(
    e: &mut Engine,
    particle: u32,
    palette: &[Color; 3],
    symbols: &[Sym],
    blink: Name,
) -> Result<(), String> {
    let phase = e.rng.randrange(0, 4) as usize;
    let period = e.rng.randint(2, 5);
    let peak_hold = e.rng.randint(1, 2);
    add_glow_scene(e, particle, blink, palette, symbols, phase, period, peak_hold)?;
    e.set_layer(particle, 1);
    Ok(())
}

/// An ember's reusable scene: a spark that cools as it rises.
fn init_ember(e: &mut Engine, particle: u32, palette: &[Color; 3], halo: Name) -> Result<(), String> {
    let scene = e.scene_new(particle, halo, false, None, None);
    let star = e.sym("*");
    let dot = e.sym(".");
    for (sym, color, duration) in [
        (star, palette[2], 3),
        (star, palette[1], 4),
        (dot, palette[1], 5),
        (dot, palette[0], 6),
    ] {
        e.add_frame(scene, sym, duration, Some(ColorPair::new(Some(color), None)), 0)?;
    }
    e.set_layer(particle, 1);
    Ok(())
}

const AUX_RESET: ParticleReset = ParticleReset {
    clear_paths: true,
    clear_scenes: false,
    clear_events: true,
    deactivate_path: true,
    deactivate_scene: true,
    reset_appearance: false,
};

impl Fireflies {
    fn symbols(&self, e: &mut Engine) -> Vec<Sym> {
        self.config
            .firefly_symbols
            .iter()
            .map(|s| e.sym(s))
            .collect()
    }

    #[allow(clippy::too_many_arguments)]
    fn build_firefly(
        &mut self,
        e: &mut Engine,
        index: usize,
        start: Coord,
        focus: Coord,
        cluster_index: usize,
        signature: (usize, i64, i64),
        symbols: &[Sym],
    ) -> Result<(), String> {
        let slot = self.fireflies[index].slot;
        let target = self.fireflies[index].target;
        let n = self.names.take().expect("names");
        let result = self.build_firefly_with(
            e,
            &n,
            index,
            slot,
            target,
            start,
            focus,
            cluster_index,
            signature,
            symbols,
        );
        self.names = Some(n);
        result
    }

    #[allow(clippy::too_many_arguments)]
    fn build_firefly_with(
        &mut self,
        e: &mut Engine,
        n: &Names,
        index: usize,
        slot: u32,
        target: Coord,
        start: Coord,
        focus: Coord,
        cluster_index: usize,
        signature: (usize, i64, i64),
        symbols: &[Sym],
    ) -> Result<(), String> {
        let config = &self.config;
        let palette = self.palette;
        let (cw, ch) = (e.canvas.width, e.canvas.height);
        let (left, right, bottom, top) =
            (e.canvas.left, e.canvas.right, e.canvas.bottom, e.canvas.top);

        // the looping glow, phased by the signature
        let (phase, period, peak_hold) = signature;
        add_glow_scene(e, slot, n.blink, &palette, symbols, phase, period, peak_hold)?;

        // entry, wander, optional orbit, approach
        let speed = (config.movement_speed * e.rng.uniform(0.75, 1.25)).max(0.01);
        // the long flights in from the edge cover more ground on a big canvas
        let far_speed = speed * self.speed_scale;
        let mut inward_column = start.column;
        let mut inward_row = start.row;
        if start.column == left {
            inward_column += 2.min(cw - 1);
        } else if start.column == right {
            inward_column -= 2.min(cw - 1);
        }
        if start.row == bottom {
            inward_row += 1.min(ch - 1);
        } else if start.row == top {
            inward_row -= 1.min(ch - 1);
        }
        let entry = clamp_coord(e, inward_column, inward_row);
        let path = e.path_new(
            slot,
            far_speed,
            Some(Easing::InOutSine),
            Some(2),
            0,
            false,
            n.enter,
        )?;
        let control = curve_control(e, start, entry);
        add_waypoint(e, path, entry, control)?;

        let path = e.path_new(
            slot,
            (far_speed * 0.75).max(0.01),
            Some(Easing::InOutSine),
            Some(2),
            0,
            false,
            n.wander,
        )?;
        let mut last = entry;
        let horizontal_radius = floor_div(cw, 4).clamp(1, 3);
        let vertical_radius = floor_div(ch, 4).clamp(1, 2);
        let mut length = 0.0;
        for _ in 0..config.wander_cycles {
            let dc = e.rng.randint(-horizontal_radius, horizontal_radius);
            let dr = e.rng.randint(-vertical_radius, vertical_radius);
            let next = clamp_coord(e, focus.column + dc, focus.row + dr);
            let control = curve_control(e, last, next);
            add_waypoint(e, path, next, control)?;
            length += find_length_of_bezier_curve(last, &[control], next);
            last = next;
        }
        // the far starters hurry, so the swarm gathers together: no wander
        // takes longer than WANDER_FRAMES per cycle at the default speed
        let budget = WANDER_FRAMES * config.wander_cycles as f64 * DEFAULT_SPEED
            / config.movement_speed;
        let wander_speed = (far_speed * 0.75).max(length / budget).max(0.01);
        e.path_set_speed(path, wander_speed);

        // waiting: slow loops around the cluster's centre, back to the end of
        // the wander
        let path = e.path_new(
            slot,
            (speed * 0.35).max(0.01),
            Some(Easing::InOutSine),
            Some(2),
            0,
            true,
            n.hover,
        )?;
        let mut from = last;
        for _ in 0..3 {
            let dc = e.rng.randint(-horizontal_radius, horizontal_radius);
            let dr = e.rng.randint(-1, 1);
            let next = clamp_coord(e, focus.column + dc, focus.row + dr);
            let control = curve_control(e, from, next);
            add_waypoint(e, path, next, control)?;
            from = next;
        }
        let control = curve_control(e, from, last);
        add_waypoint(e, path, last, control)?;

        let has_orbit = cw >= 3 && ch >= 2 && cluster_index % 3 == 1;
        if has_orbit {
            let path = e.path_new(
                slot,
                speed,
                Some(Easing::InOutSine),
                Some(2),
                0,
                false,
                n.orbit,
            )?;
            let first = clamp_coord(e, focus.column - 1, focus.row + 1);
            let second = clamp_coord(e, focus.column + 1, focus.row - 1);
            let control = curve_control(e, last, first);
            add_waypoint(e, path, first, control)?;
            let control = curve_control(e, first, second);
            add_waypoint(e, path, second, control)?;
            last = second;
        }

        let path = e.path_new(
            slot,
            (speed * 1.4).max(0.01),
            Some(Easing::InOutQuad),
            Some(2),
            0,
            false,
            n.approach,
        )?;
        let column_direction = if target.column >= focus.column { 1 } else { -1 };
        let row_direction = if target.row >= focus.row { 1 } else { -1 };
        let overshoot = clamp_coord(
            e,
            target.column + column_direction,
            target.row + row_direction,
        );
        let control = curve_control(e, last, overshoot);
        add_waypoint(e, path, overshoot, control)?;
        let control = curve_control(e, overshoot, target);
        add_waypoint(e, path, target, control)?;

        // landing: the peak symbol, the input symbol, a slow cool-down to the
        // final color
        let final_colors = self.final_colors[index];
        let peak = palette[2];
        let brightest = *config.firefly_colors.last().expect("firefly colors");
        let input = e.input_sym(slot);
        let last_symbol = *symbols.last().expect("firefly symbols");
        let bg = final_colors.bg_color;
        let lit = |c: Color| Some(ColorPair::new(Some(c), bg));
        let landing = e.scene_new(slot, n.landing, false, None, None);
        e.add_frame(landing, last_symbol, 3, lit(peak), 0)?;
        e.add_frame(landing, input, 3, lit(brightest), 0)?;
        let cool: Vec<Color> = match final_colors.fg_color {
            Some(fg) => Gradient::with_steps(&[peak, fg], 8, false)?.spectrum,
            None => vec![
                peak,
                Animation::adjust_color_brightness(&peak, 0.75),
                Animation::adjust_color_brightness(&peak, 0.55),
            ],
        };
        for color in cool {
            e.add_frame(landing, input, 2, lit(color), 0)?;
        }
        e.add_frame(landing, input, 2, Some(final_colors), 0)?;

        let arg = index as i64;
        e.register_event(
            slot,
            Event::SceneComplete,
            Caller::Scene(n.landing),
            Action::Callback(SETTLE, arg),
        )?;
        e.register_event(
            slot,
            Event::PathComplete,
            Caller::Path(n.enter),
            Action::Callback(FINISH_ENTRY, arg),
        )?;
        e.register_event(
            slot,
            Event::PathComplete,
            Caller::Path(n.wander),
            Action::Callback(FINISH_WANDER, arg),
        )?;
        if has_orbit {
            e.register_event(
                slot,
                Event::PathComplete,
                Caller::Path(n.orbit),
                Action::Callback(FINISH_ORBIT, arg),
            )?;
        }
        e.register_event(
            slot,
            Event::PathComplete,
            Caller::Path(n.approach),
            Action::Callback(LAND, arg),
        )?;
        self.fireflies[index].has_orbit = has_orbit;
        Ok(())
    }

    fn activate_approach(&mut self, e: &mut Engine, index: usize) {
        let slot = self.fireflies[index].slot;
        let (orbit, approach) = (self.names().orbit, self.names().approach);
        if self.fireflies[index].has_orbit {
            self.fireflies[index].state = State::Orbiting;
            e.activate_path_name(self, slot, orbit);
        } else {
            self.fireflies[index].state = State::Approaching;
            e.activate_path_name(self, slot, approach);
        }
        e.active_insert(slot);
    }

    /// Sometimes an ember rises off a landed character: only from the top
    /// edge of the text (the cells it rises through are empty), and only
    /// while one is free.
    fn emit_ember(&mut self, e: &mut Engine, origin: Coord) {
        let Some(mut pool) = self.embers.take() else {
            return;
        };
        let column = origin.column + e.rng.randint(-1, 1);
        let clear = (1..=3).all(|up| {
            let cell = Coord::new(column, origin.row + up);
            e.canvas.coord_is_in_canvas(cell) && !self.text_cells.contains(&cell)
        });
        if clear && !pool.available.is_empty() {
            let (halo, rise) = (self.names().halo, self.names().rise);
            let sym = self.halo_sym;
            let drift = e.rng.randint(-1, 1);
            pool.emit(
                e,
                Coord::new(column, origin.row + 1),
                Some(sym),
                true,
                AUX_RESET,
                |_, _| {},
                |e, particle| {
                    if let Ok(path) =
                        e.path_new(particle, 0.1, Some(Easing::OutSine), Some(1), 0, false, rise)
                    {
                        let end = clamp_coord(e, column + drift, origin.row + 3);
                        if e.path_new_waypoint(path, end, None, Name::NONE).is_ok() {
                            e.activate_path(&mut NoHooks, particle, path);
                        }
                    }
                    if let Some(scene) = e.scene_find(particle, halo) {
                        e.scene_reset(scene);
                        let _ = e.register_event(
                            particle,
                            Event::SceneComplete,
                            Caller::Scene(halo),
                            Action::Callback(RECLAIM_EMBER, 0),
                        );
                        e.activate_scene(&mut NoHooks, particle, scene);
                    }
                },
            );
        }
        self.embers = Some(pool);
    }

    fn emit_due_auxiliaries(&mut self, e: &mut Engine) {
        let Some(mut pool) = self.pool.take() else {
            return;
        };
        let (blink, atmosphere) = (self.names().blink, self.names().atmosphere);
        let speed_base = self.config.movement_speed * self.speed_scale;
        let waypoints = self.config.wander_cycles + 2;
        while self.aux_next < self.aux_activation_frames.len()
            && self.frame_count >= self.aux_activation_frames[self.aux_next]
        {
            self.aux_next += 1;
            let origin = self.perimeter[e.rng.choice_index(self.perimeter.len())];
            pool.emit(
                e,
                origin,
                None,
                true,
                AUX_RESET,
                |_, _| {},
                |e, particle| {
                    let speed = (speed_base * e.rng.uniform(0.7, 1.1)).max(0.01);
                    let Ok(path) = e.path_new(
                        particle,
                        speed,
                        Some(Easing::InOutSine),
                        Some(1),
                        0,
                        true,
                        atmosphere,
                    ) else {
                        return;
                    };
                    let mut last = e.coord(particle);
                    for _ in 0..waypoints {
                        let next = e.canvas.clone().random_coord(&mut e.rng, false, false);
                        let control = curve_control(e, last, next);
                        let _ = add_waypoint(e, path, next, control);
                        last = next;
                    }
                    if let Some(scene) = e.scene_find(particle, blink) {
                        e.scene_reset(scene);
                        e.activate_scene(&mut NoHooks, particle, scene);
                    }
                    e.activate_path(&mut NoHooks, particle, path);
                },
            );
        }
        self.pool = Some(pool);
    }

    /// Send every emitted helper beyond a canvas edge.
    fn depart_auxiliaries(&mut self, e: &mut Engine) {
        if self.aux_departed {
            return;
        }
        self.aux_departed = true;
        self.aux_next = self.aux_activation_frames.len();
        let Some(pool) = self.pool.as_ref() else {
            return;
        };
        let particles: Vec<u32> = pool
            .particles
            .iter()
            .copied()
            .filter(|p| !pool.available.contains(p))
            .collect();
        let depart = self.names().depart;
        let speed = (self.config.movement_speed * 1.6 * self.speed_scale).max(0.01);
        let palette = self.palette;
        for particle in particles {
            // out through the nearest edge
            let c = e.canvas.clone();
            let here = e.coord(particle);
            let slide = e.rng.randint(-4, 4);
            let gaps = [
                (here.column - c.left, Coord::new(c.left - 1, here.row + slide)),
                (c.right - here.column, Coord::new(c.right + 1, here.row + slide)),
                (2 * (here.row - c.bottom), Coord::new(here.column + 2 * slide, c.bottom - 1)),
                (2 * (c.top - here.row), Coord::new(here.column + 2 * slide, c.top + 1)),
            ];
            let target = gaps.iter().min_by_key(|g| g.0).map_or(here, |g| g.1);
            if let Some(old) = e.path_find(particle, depart) {
                e.path_reset(old);
            }
            let path = match e.path_find(particle, depart) {
                Some(path) => path,
                None => match e.path_new(
                    particle,
                    speed,
                    Some(Easing::InSine),
                    Some(1),
                    0,
                    false,
                    depart,
                ) {
                    Ok(path) => path,
                    Err(_) => continue,
                },
            };
            let current = e.coord(particle);
            let control = curve_control(e, current, target);
            if add_waypoint(e, path, target, control).is_err() {
                continue;
            }
            let scene = e.scene_new(particle, depart, false, Some(SyncMetric::Distance), None);
            let sym = e.input_sym(particle);
            for &color in palette.iter().rev() {
                let _ = e.add_frame(scene, sym, 2, Some(ColorPair::new(Some(color), None)), 0);
            }
            let _ = e.register_event(
                particle,
                Event::PathComplete,
                Caller::Path(depart),
                Action::Callback(RECLAIM, 0),
            );
            e.activate_scene(self, particle, scene);
            e.activate_path(self, particle, path);
            e.active_insert(particle);
        }
    }

    fn step_auxiliaries(&mut self, e: &mut Engine) {
        if self.pool.as_ref().is_none_or(|p| p.is_empty()) {
            return;
        }
        if !self.aux_departed {
            self.emit_due_auxiliaries(e);
            let ratio = if self.fireflies.is_empty() {
                1.0
            } else {
                self.settled as f64 / self.fireflies.len() as f64
            };
            // they roam until the whole cascade is out
            let released = self
                .cascade_start
                .is_some_and(|start| self.frame_count >= start + self.last_release_offset);
            if released || ratio >= 0.9 {
                self.depart_auxiliaries(e);
            }
        }
        let pool = self.pool.as_ref().unwrap();
        for i in 0..pool.particles.len() {
            let particle = pool.particles[i];
            if !pool.available.contains(&particle) && e.is_visible(particle) {
                e.active_insert(particle);
            }
        }
    }

    fn step_reveal(&mut self, e: &mut Engine) {
        self.step_auxiliaries(e);
        let (blink, enter) = (self.names().blink, self.names().enter);
        for index in 0..self.fireflies.len() {
            let f = &self.fireflies[index];
            let slot = f.slot;
            if f.state == State::Dormant && self.frame_count >= f.activation_frame {
                self.fireflies[index].state = State::Entering;
                e.set_visible(slot, true);
                e.activate_scene_name(self, slot, blink);
                e.activate_path_name(self, slot, enter);
            }
            let f = &self.fireflies[index];
            if f.state == State::Gathering && self.frame_count >= f.release_frame {
                self.activate_approach(e, index);
            }
            let state = self.fireflies[index].state;
            if state != State::Dormant && state != State::Settled {
                e.active_insert(slot);
            }
        }
        e.update(self);
        // once most of the swarm hovers around the text, the cascade starts
        if self.cascade_start.is_none()
            && self.gathered as f64 >= self.fireflies.len() as f64 * GATHERED_SHARE
        {
            let start = self.frame_count + HOVER_BEAT;
            self.cascade_start = Some(start);
            for f in &mut self.fireflies {
                f.release_frame = start + f.release_offset;
            }
        }
        let home = |p: &Option<ParticlePool>| {
            p.as_ref().is_none_or(|p| p.available.len() == p.len())
        };
        if !self.fireflies.is_empty()
            && self.settled == self.fireflies.len()
            && home(&self.pool)
            && home(&self.embers)
        {
            self.prepare_flourish(e);
        }
    }

    fn lantern_orbit_pos(&self, lantern: &Lantern, progress: f64) -> (f64, f64) {
        let (cx, cy) = self.text_center;
        let (rx, ry) = (self.orbit_rx, self.orbit_ry);
        let tau = std::f64::consts::TAU;
        match lantern.kind {
            OrbitKind::FigureEight => {
                let theta = lantern.phase + 1.25 * tau * progress;
                (
                    cx + rx * 0.96 * theta.sin(),
                    cy + ry * 0.86 * (2.0 * theta).sin(),
                )
            }
            OrbitKind::OuterHalo => {
                let theta = lantern.phase - 1.05 * tau * progress;
                (
                    cx + rx * 1.04 * theta.cos(),
                    cy + ry * 1.02 * theta.sin() + ry * 0.16 * (3.0 * theta).sin(),
                )
            }
            OrbitKind::CounterRibbon => {
                let theta = lantern.phase + 1.15 * tau * progress;
                (
                    cx - rx * 0.88 * theta.cos(),
                    cy + ry * 0.72 * (2.0 * theta + 0.7).sin(),
                )
            }
        }
    }

    /// Set up the signature lantern flourish: 2-3 fireflies swoop in around
    /// the finished logo, weave figure-eight and halo orbits while warming
    /// every letter they pass, then drift away into the night.
    fn prepare_flourish(&mut self, e: &mut Engine) {
        if self.lanterns.is_empty() {
            self.phase = Phase::Complete;
            return;
        }
        for idx in 0..self.lanterns.len() {
            let (ox, oy) = self.lantern_orbit_pos(&self.lanterns[idx], 0.0);
            let lantern = &mut self.lanterns[idx];
            lantern.history.clear();
            lantern.last_x = ox;
            lantern.last_y = oy;
            e.set_visible(lantern.slot, false);
            for &t in &lantern.trail {
                e.set_visible(t, false);
            }
        }
        self.heat.fill(0.0);
        self.heat_level.fill(0);
        self.flourish_tick = 0;
        self.phase = Phase::Flourish;
    }

    fn apply_letter_heat(&self, e: &mut Engine, index: usize, level: u8) {
        let slot = self.fireflies[index].slot;
        let base = self.final_colors[index];
        if level == 0 {
            e.set_appearance(slot, None, Some(base));
            return;
        }
        let t = level as f64 / HEAT_LEVELS as f64;
        let brightest = *self
            .config
            .firefly_colors
            .last()
            .unwrap_or(&self.palette[2]);
        let warm_peak = lerp_color(brightest, Color::from_rgb(255, 252, 224), 0.48);
        let fg = match base.fg_color {
            Some(fg) => {
                if t <= 0.6 {
                    lerp_color(fg, self.palette[2], t / 0.6)
                } else {
                    lerp_color(self.palette[2], warm_peak, (t - 0.6) / 0.4)
                }
            }
            None => lerp_color(self.palette[0], warm_peak, t),
        };
        let bg = match base.bg_color {
            Some(existing_bg) => Some(existing_bg),
            None if t > 0.25 => {
                let a = ((t - 0.25) / 0.75).clamp(0.0, 1.0);
                Some(Color::from_rgb(
                    (54.0 * a).round() as u8,
                    (40.0 * a).round() as u8,
                    (10.0 * a).round() as u8,
                ))
            }
            None => None,
        };
        e.set_appearance(slot, None, Some(ColorPair::new(Some(fg), bg)));
    }

    fn step_flourish(&mut self, e: &mut Engine) {
        let tick = self.flourish_tick;
        let enter_end = self.flourish_enter;
        let orbit_end = enter_end + self.flourish_orbit;
        let total_end = orbit_end + self.flourish_exit;

        let brightest = *self
            .config
            .firefly_colors
            .last()
            .unwrap_or(&self.palette[2]);
        let warm_white = lerp_color(brightest, Color::from_rgb(255, 253, 232), 0.35);

        // Compute current positions and glow strengths for each lantern firefly.
        let mut active_lanterns: Vec<(f64, f64, f64)> = Vec::with_capacity(self.lanterns.len());
        let mut ember_origin: Option<Coord> = None;

        for idx in 0..self.lanterns.len() {
            let (x, y, visibility) = if tick < enter_end {
                let u = tick as f64 / enter_end.max(1) as f64;
                let ease = 1.0 - (1.0 - u).powi(3);
                let (ox, oy) = self.lantern_orbit_pos(&self.lanterns[idx], 0.0);
                let dx = ox - self.text_center.0;
                let dy = oy - self.text_center.1;
                let len = (dx * dx + dy * dy).sqrt().max(1.0);
                let sx = ox + (dx / len) * (self.orbit_rx * 0.25).clamp(4.0, 12.0);
                let sy = oy + (dy / len) * (self.orbit_ry * 0.35).clamp(2.0, 5.0);
                let x = sx + (ox - sx) * ease;
                let y = sy + (oy - sy) * ease;
                (x, y, ease)
            } else if tick < orbit_end {
                let progress = (tick - enter_end) as f64 / self.flourish_orbit.max(1) as f64;
                let (x, y) = self.lantern_orbit_pos(&self.lanterns[idx], progress);
                self.lanterns[idx].last_x = x;
                self.lanterns[idx].last_y = y;
                (x, y, 1.0)
            } else if tick < total_end {
                let u = (tick - orbit_end) as f64 / self.flourish_exit.max(1) as f64;
                let extra_progress = 1.0 + 0.14 * (1.0 - (1.0 - u).powi(2));
                let (ox, oy) = self.lantern_orbit_pos(&self.lanterns[idx], extra_progress);
                let drift = u * u;
                let x = ox + self.lanterns[idx].exit_dx * drift;
                let y = oy + self.lanterns[idx].exit_dy * drift;
                let fade = (1.0 - u).powf(1.5);
                (x, y, fade)
            } else {
                (self.lanterns[idx].last_x, self.lanterns[idx].last_y, 0.0)
            };

            let pulse_wave =
                0.5 + 0.5 * (tick as f64 * self.lanterns[idx].pulse_freq + self.lanterns[idx].pulse_phase).sin();
            let pulse = 0.58 + 0.42 * pulse_wave.powf(1.5);
            let intensity = (visibility * pulse).clamp(0.0, 1.0);

            let coord = Coord::new(x.round() as i64, y.round() as i64);
            let in_canvas = e.canvas.coord_is_in_canvas(coord);
            let slot = self.lanterns[idx].slot;

            if visibility > 0.04 && in_canvas {
                e.set_coordinate(slot, coord);
                let syms = &self.firefly_syms;
                let sym = if intensity > 0.78 {
                    syms[2 % syms.len()]
                } else if intensity > 0.46 {
                    syms[1 % syms.len()]
                } else {
                    syms[0]
                };
                let color = if intensity > 0.78 {
                    lerp_color(self.palette[2], warm_white, (intensity - 0.78) / 0.22)
                } else if intensity > 0.42 {
                    lerp_color(self.palette[1], self.palette[2], (intensity - 0.42) / 0.36)
                } else {
                    lerp_color(self.palette[0], self.palette[1], intensity / 0.42)
                };
                let halo_bg = if !self.text_cells.contains(&coord) && intensity > 0.30 {
                    let a = ((intensity - 0.30) / 0.70).clamp(0.0, 1.0);
                    Some(Color::from_rgb(
                        (82.0 * a).round() as u8,
                        (62.0 * a).round() as u8,
                        (14.0 * a).round() as u8,
                    ))
                } else {
                    None
                };
                e.set_appearance(slot, Some(sym), Some(ColorPair::new(Some(color), halo_bg)));
                e.set_visible(slot, true);

                let history = &mut self.lanterns[idx].history;
                if history.last().copied() != Some(coord) {
                    history.push(coord);
                    if history.len() > 7 {
                        history.remove(0);
                    }
                }

                // Trail sparks render only on empty cells so the logo stays crisp.
                let trail_slots = self.lanterns[idx].trail;
                let hist_len = self.lanterns[idx].history.len();
                let trail_colors = [
                    lerp_color(self.palette[1], self.palette[2], 0.55 * visibility),
                    lerp_color(self.palette[0], self.palette[1], 0.80 * visibility),
                    lerp_color(self.palette[0], self.palette[1], 0.40 * visibility),
                    lerp_color(Color::from_rgb(28, 22, 8), self.palette[0], visibility),
                ];
                let trail_syms = [
                    self.wake_syms[0],
                    self.wake_syms[0],
                    self.wake_syms[1],
                    self.wake_syms[1],
                ];
                for (k, &t_slot) in trail_slots.iter().enumerate() {
                    let back = k + 2;
                    if visibility > 0.14 && hist_len >= back {
                        let tc = self.lanterns[idx].history[hist_len - back];
                        if tc != coord
                            && e.canvas.coord_is_in_canvas(tc)
                            && !self.text_cells.contains(&tc)
                        {
                            let t_bg = if k == 0 && intensity > 0.45 {
                                let a = ((intensity - 0.45) / 0.55).clamp(0.0, 1.0) * visibility;
                                Some(Color::from_rgb(
                                    (30.0 * a).round() as u8,
                                    (22.0 * a).round() as u8,
                                    (5.0 * a).round() as u8,
                                ))
                            } else {
                                None
                            };
                            e.set_coordinate(t_slot, tc);
                            e.set_appearance(
                                t_slot,
                                Some(trail_syms[k]),
                                Some(ColorPair::new(Some(trail_colors[k]), t_bg)),
                            );
                            e.set_visible(t_slot, true);
                        } else {
                            e.set_visible(t_slot, false);
                        }
                    } else {
                        e.set_visible(t_slot, false);
                    }
                }

                active_lanterns.push((x, y, intensity));

                // Occasionally release a tiny rising ember when peaking near the logo.
                if ember_origin.is_none()
                    && tick >= enter_end
                    && tick < orbit_end - 25
                    && (tick + idx as i64 * 17) % 38 == 0
                    && intensity > 0.72
                {
                    ember_origin = Some(coord);
                }
            } else {
                e.set_visible(slot, false);
                for &t_slot in &self.lanterns[idx].trail {
                    e.set_visible(t_slot, false);
                }
            }
        }

        // Warm nearby letters and decay existing afterglow smoothly.
        let inv_rx = 1.0 / self.glow_rx.max(1.0);
        let inv_ry = 1.0 / self.glow_ry.max(1.0);
        let mut any_warm = false;
        for i in 0..self.fireflies.len() {
            let mut h = (self.heat[i] - HEAT_DECAY).max(0.0);
            if !active_lanterns.is_empty() {
                let target = self.fireflies[i].target;
                let tc = target.column as f64;
                let tr = target.row as f64;
                for &(lx, ly, intensity) in &active_lanterns {
                    let dx = (tc - lx) * inv_rx;
                    let dy = (tr - ly) * inv_ry;
                    let d2 = dx * dx + dy * dy;
                    if d2 < 1.0 {
                        let falloff = (1.0 - d2) * (1.0 - d2);
                        let impulse = (falloff * (0.65 + 0.35 * intensity)) as f32;
                        if impulse > h {
                            h = impulse;
                        }
                    }
                }
            }
            self.heat[i] = h;
            let level = ((h * HEAT_LEVELS as f32).round() as u8).min(HEAT_LEVELS);
            if level != self.heat_level[i] {
                self.heat_level[i] = level;
                self.apply_letter_heat(e, i, level);
            }
            if level > 0 {
                any_warm = true;
            }
        }

        if let Some(origin) = ember_origin {
            self.emit_ember(e, origin);
        }

        e.update(self);
        self.flourish_tick += 1;

        let embers_home = self
            .embers
            .as_ref()
            .is_none_or(|p| p.available.len() == p.len());
        if self.flourish_tick >= total_end && !any_warm && embers_home && e.active_is_empty() {
            // Ensure every lantern and trail slot is hidden and every letter is exact.
            for lantern in &self.lanterns {
                e.set_visible(lantern.slot, false);
                for &t_slot in &lantern.trail {
                    e.set_visible(t_slot, false);
                }
            }
            for i in 0..self.fireflies.len() {
                if self.heat_level[i] != 0 {
                    self.heat_level[i] = 0;
                    self.apply_letter_heat(e, i, 0);
                }
            }
            self.phase = Phase::Complete;
        }
    }
}

/// Hooks for activations that fire no registered events.
struct NoHooks;
impl Hooks for NoHooks {}

impl Hooks for Fireflies {
    fn callback(&mut self, e: &mut Engine, slot: u32, id: u32, arg: i64) {
        let index = arg as usize;
        match id {
            FINISH_ENTRY => {
                self.fireflies[index].state = State::Wandering;
                let wander = self.names().wander;
                e.activate_path_name(self, slot, wander);
            }
            FINISH_WANDER => {
                self.fireflies[index].state = State::Gathering;
                self.gathered += 1;
                let hover = self.names().hover;
                e.activate_path_name(self, slot, hover);
            }
            FINISH_ORBIT => {
                self.fireflies[index].state = State::Approaching;
                let approach = self.names().approach;
                e.activate_path_name(self, slot, approach);
            }
            LAND => {
                let target = self.fireflies[index].target;
                e.set_coordinate(slot, target);
                self.fireflies[index].state = State::Illuminating;
                let landing = self.names().landing;
                e.activate_scene_name(self, slot, landing);
                self.emit_ember(e, target);
            }
            SETTLE => {
                let input = e.input_coord(slot);
                e.set_coordinate(slot, input);
                e.set_appearance(slot, None, Some(self.final_colors[index]));
                e.set_layer(slot, 0);
                if self.fireflies[index].state != State::Settled {
                    self.fireflies[index].state = State::Settled;
                    self.settled += 1;
                }
            }
            RECLAIM => {
                if let Some(mut pool) = self.pool.take() {
                    pool.reclaim(e, slot, true, true);
                    self.pool = Some(pool);
                }
            }
            RECLAIM_EMBER => {
                if let Some(mut pool) = self.embers.take() {
                    pool.reclaim(e, slot, true, true);
                    self.embers = Some(pool);
                }
            }
            _ => {}
        }
    }
}

impl Effect for Fireflies {
    fn build(&mut self, e: &mut Engine) -> Result<(), EngineError> {
        let config = self.config.clone();
        self.phase = Phase::Complete;
        if config.firefly_colors.is_empty() || config.firefly_symbols.is_empty() {
            return Ok(());
        }
        self.palette = blink_palette(&config.firefly_colors).map_err(other)?;
        self.halo_sym = e.sym("*");
        self.names = Some(Names {
            enter: e.name("enter"),
            wander: e.name("wander"),
            hover: e.name("hover"),
            rise: e.name("rise"),
            orbit: e.name("orbit"),
            approach: e.name("approach"),
            atmosphere: e.name("atmosphere"),
            depart: e.name("depart"),
            blink: e.name("blink"),
            landing: e.name("landing"),
            halo: e.name("halo"),
        });
        let characters = e.get_characters(
            CharacterFilter::default(),
            CharacterSort::TopToBottomLeftToRight,
        );
        if characters.is_empty() {
            return Ok(());
        }
        let canvas = e.canvas.clone();
        let final_gradient = Gradient::new(
            &config.final_gradient_stops,
            &config.final_gradient_steps,
            false,
            false,
        )
        .map_err(other)?;
        let final_mapping = final_gradient
            .build_coordinate_color_mapping(
                canvas.text_bottom,
                canvas.text_top,
                canvas.text_left,
                canvas.text_right,
                config.final_gradient_direction,
            )
            .map_err(other)?;
        let fallback = *final_gradient.spectrum.last().expect("final gradient");
        let input_colors = matches!(
            e.existing_color_handling(),
            ExistingColorHandling::Dynamic | ExistingColorHandling::Always
        );
        let final_color = |e: &Engine, slot: u32| {
            if input_colors {
                ColorPair::new(e.input_fg(slot), e.input_bg(slot))
            } else {
                let c = final_mapping
                    .get(&e.input_coord(slot))
                    .copied()
                    .unwrap_or(fallback);
                ColorPair::new(Some(c), None)
            }
        };

        // 4x2 clusters, in first-seen order, then shuffled
        let mut bucket_keys: Vec<(i64, i64)> = Vec::new();
        let mut buckets: Vec<Vec<u32>> = Vec::new();
        let mut index_of: std::collections::HashMap<(i64, i64), usize, crate::fx::FxBuild> =
            Default::default();
        for &slot in &characters {
            let c = e.input_coord(slot);
            let key = (
                floor_div(c.column - canvas.text_left, CLUSTER_WIDTH),
                floor_div(c.row - canvas.text_bottom, CLUSTER_HEIGHT),
            );
            let b = *index_of.entry(key).or_insert_with(|| {
                bucket_keys.push(key);
                buckets.push(Vec::new());
                buckets.len() - 1
            });
            buckets[b].push(slot);
        }
        let mut order: Vec<usize> = (0..buckets.len()).collect();
        e.rng.shuffle(&mut order);

        let mut signatures: Vec<(usize, i64, i64)> = Vec::with_capacity(32);
        for phase in 0..4 {
            for period in 2..6 {
                for peak_hold in 1..3 {
                    signatures.push((phase, period, peak_hold));
                }
            }
        }
        e.rng.shuffle(&mut signatures);
        self.perimeter = perimeter_coords(e);
        let symbols = self.symbols(e);
        let area = canvas.width.max(0) * canvas.height.max(0);
        self.speed_scale = (area as f64 / REFERENCE_AREA).sqrt().max(1.0);
        self.text_cells = characters.iter().map(|&s| e.input_coord(s)).collect();

        // the original's per-cluster spacing (2 frames to emerge, 9 to land)
        // up to SPREAD_CLUSTERS clusters; more share the same budget
        let spread = (order.len() as f64).max(SPREAD_CLUSTERS);
        let emerge_step = EMERGE_FRAMES / spread;
        let landing_step = config.landing_duration as f64 / spread;

        for (cluster_id, &b) in order.iter().enumerate() {
            let mut cluster = std::mem::take(&mut buckets[b]);
            e.rng.shuffle(&mut cluster);
            let len = cluster.len() as f64;
            let sum_column: i64 = cluster.iter().map(|&s| e.input_coord(s).column).sum();
            let sum_row: i64 = cluster.iter().map(|&s| e.input_coord(s).row).sum();
            let focus = clamp_coord(
                e,
                round_half_even(sum_column as f64 / len),
                round_half_even(sum_row as f64 / len),
            );
            let cid = cluster_id as f64;
            let release = (cid * landing_step).round() as i64 + e.rng.randint(0, 6);
            for (character_index, &slot) in cluster.iter().enumerate() {
                let index = self.fireflies.len();
                let start = self.perimeter[e.rng.choice_index(self.perimeter.len())];
                let activation_frame = (cid * emerge_step).round() as i64 + e.rng.randint(1, 8);
                let release_offset = release + e.rng.randint(0, 3);
                self.last_release_offset = self.last_release_offset.max(release_offset);
                self.fireflies.push(Firefly {
                    slot,
                    target: e.input_coord(slot),
                    activation_frame,
                    release_offset,
                    release_frame: i64::MAX,
                    has_orbit: false,
                    state: State::Dormant,
                });
                self.final_colors.push(final_color(e, slot));
                e.set_coordinate(slot, start);
                let signature = signatures[index % signatures.len()];
                self.build_firefly(e, index, start, focus, character_index, signature, &symbols)
                    .map_err(other)?;
            }
        }

        // the atmospheric helpers
        let effective = config.auxiliary_count.min(12).min(area / 8).max(0) as usize;
        let mut pool = ParticlePool::new(symbols.clone(), Some(effective), None).map_err(other)?;
        let palette = self.palette;
        let (blink, halo) = (self.names().blink, self.names().halo);
        let mut init_error = None;
        pool.preallocate(e, effective, |e, particle| {
            if let Err(err) = init_auxiliary(e, particle, &palette, &symbols, blink) {
                init_error = Some(err);
            }
        })
        .map_err(other)?;
        // the embers rising off landed letters
        let ember_count = EMBERS.min(self.fireflies.len());
        let mut embers =
            ParticlePool::new(vec![self.halo_sym], Some(ember_count), None).map_err(other)?;
        embers
            .preallocate(e, ember_count, |e, particle| {
                if let Err(err) = init_ember(e, particle, &palette, halo) {
                    init_error = Some(err);
                }
            })
            .map_err(other)?;
        if let Some(err) = init_error {
            return Err(other(err));
        }
        self.embers = Some(embers);
        let mut frames: Vec<i64> = (0..effective).map(|_| e.rng.randint(1, 6)).collect();
        frames.sort_unstable();
        self.aux_activation_frames = frames;
        self.aux_next = 0;
        self.aux_departed = false;
        self.pool = Some(pool);

        // Pre-allocate the dedicated lantern fireflies and their wake sparks.
        self.firefly_syms = symbols.clone();
        self.wake_syms = [e.sym("·"), e.sym(".")];
        self.heat = vec![0.0; self.fireflies.len()];
        self.heat_level = vec![0; self.fireflies.len()];
        let cx = (canvas.text_left + canvas.text_right) as f64 * 0.5;
        let cy = (canvas.text_bottom + canvas.text_top) as f64 * 0.5;
        let half_w = ((canvas.text_right - canvas.text_left) as f64 * 0.5).max(1.0);
        let half_h = ((canvas.text_top - canvas.text_bottom) as f64 * 0.5).max(1.0);
        let pad_x = (half_w * 0.16).clamp(2.5, 9.0);
        let pad_y = (half_h * 0.65).clamp(3.0, 5.5);
        self.text_center = (cx, cy);
        self.orbit_rx = (half_w + pad_x)
            .min((canvas.width as f64 - 2.0) * 0.48)
            .max(1.0);
        self.orbit_ry = (half_h + pad_y)
            .min((canvas.height as f64 - 2.0) * 0.46)
            .max(0.8);
        self.glow_rx = (half_w * 0.22).clamp(4.5, 9.0);
        self.glow_ry = (half_h * 0.80).clamp(2.5, 4.8);

        self.lanterns.clear();
        if canvas.width >= 6 && canvas.height >= 3 {
            let lantern_count = if canvas.width >= 24 && canvas.height >= 6 {
                3
            } else {
                2
            };
            let specs = [
                (OrbitKind::FigureEight, 0.35, 0.105, 0.0, 14.0, 6.0),
                (OrbitKind::OuterHalo, 2.45, 0.092, 2.1, -15.0, 7.0),
                (OrbitKind::CounterRibbon, 4.55, 0.118, 4.2, 12.0, -5.0),
            ];
            let home_coord = clamp_coord(e, cx.round() as i64, cy.round() as i64);
            let lead_sym = symbols[0];
            for &(kind, base_phase, pulse_freq, pulse_phase, exit_dx, exit_dy) in
                specs.iter().take(lantern_count)
            {
                let slot = e.add_character_sym(lead_sym, home_coord);
                e.set_layer(slot, 2);
                e.set_visible(slot, false);
                let mut trail = [0u32; 4];
                for t_slot in &mut trail {
                    let s = e.add_character_sym(self.wake_syms[0], home_coord);
                    e.set_layer(s, 1);
                    e.set_visible(s, false);
                    *t_slot = s;
                }
                let jitter = e.rng.uniform(-0.35, 0.35);
                self.lanterns.push(Lantern {
                    slot,
                    trail,
                    history: Vec::with_capacity(7),
                    kind,
                    phase: base_phase + jitter,
                    pulse_freq,
                    pulse_phase: pulse_phase + e.rng.uniform(0.0, 1.5),
                    exit_dx,
                    exit_dy,
                    last_x: cx,
                    last_y: cy,
                });
            }
        }
        self.flourish_enter = FLOURISH_ENTER;
        self.flourish_orbit = FLOURISH_ORBIT;
        self.flourish_exit = FLOURISH_EXIT;
        self.flourish_tick = 0;

        self.frame_count = 0;
        self.settled = 0;
        self.gathered = 0;
        self.cascade_start = None;
        self.phase = Phase::Reveal;
        Ok(())
    }

    fn next_frame(&mut self, e: &mut Engine) -> bool {
        match self.phase {
            Phase::Complete => false,
            Phase::Reveal => {
                self.frame_count += 1;
                self.step_reveal(e);
                true
            }
            Phase::Flourish => {
                self.frame_count += 1;
                self.step_flourish(e);
                true
            }
        }
    }
}
