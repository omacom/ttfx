//! snake: snakes slither in from the canvas edges carrying the input
//! characters and lay them down one by one, assembling the text.
//!
//! Original effect by Tushar Malpani (@tusharmalpani20), https://github.com/tusharmalpani20/tte-community-effects, MIT.
//! (Python TerminalTextEffects plugin, ChrisBuilds/terminaltexteffects#73.)
//!
//! As in the original, every snake carries a share of the input characters
//! and walks orthogonal grid routes (at most one corner per leg, alternating
//! horizontal-first and vertical-first) to drop each one at its place, where
//! it settles from a bright glint of the snake's color into its final color.
//!
//! What this port adds, so the snakes read as snakes and the text builds in
//! an order that makes sense:
//!
//! * The text is cut into `--snake-count` vertical bands of equal work, left
//!   to right. The outer bands' snakes come in from the left and right edges,
//!   the inner ones alternately from the top and the bottom, each from a
//!   random point on its edge, by a meandering two-leg route (faster than it
//!   lays). Each snake then mows its band row by row, turning at the band's
//!   ends (left and top snakes from the top down, the others from the bottom
//!   up), so the letters grow out of four tidy runs instead of crossing paths.
//! * The body is the next `--body-length` characters the snake carries,
//!   shown as their own glyphs on the cells the head just crossed (it unrolls
//!   from the head on entry, it does not pile up). The rest of the load is
//!   out of sight; the snake grows shorter only as its last characters go.
//!   The body is shaded head to tail with banded scales and a slow ripple
//!   running down it, the head is a bright `--head-symbol`, and now and then
//!   a red tongue flicks out ahead of it.
//! * Every head step is one grid cell: the head moves `--movement-speed`
//!   times a base pace of cells per frame (the pace grows with very long
//!   texts so a run stays seconds, not minutes). Snakes spawn
//!   `--spawn-delay` frames apart; a snake's head and tongue vanish when
//!   its last character is down.
//! * Once the text is assembled, a sleek keeper snake emerges from the
//!   leftmost hollow cavity (the "O" in OMARCHY, or the top-left corner on
//!   plain text), patrols clockwise along the logo's skyline contour with
//!   flicking tongue and a soft emerald wake, and slips back into the "O"
//!   to curl and tuck its tail cleanly away.

use std::collections::{HashSet, VecDeque};

use clap::Args;

use crate::cli::parse_color;
use crate::effects::common::{
    parse_gradient_direction, parse_gradient_steps, parse_non_negative_int, parse_positive_float,
    parse_positive_int, parse_symbol,
};
use crate::engine::animation::ExistingColorHandling;
use crate::engine::error::EngineError;
use crate::engine::terminal::{CharacterFilter, CharacterSort};
use crate::fx::run::Effect;
use crate::fx::{Engine, Hooks, Name, Sym, NONE};
use crate::utils::geometry::Coord;
use crate::utils::graphics::{Color, ColorPair, Gradient, GradientDirection};

#[derive(Args, Debug, Clone)]
pub struct SnakeConfig {
    /// Maximum number of snakes. The effective count is limited by the number of input characters.
    #[arg(long = "snake-count", default_value_t = 4, value_parser = parse_positive_int)]
    pub snake_count: i64,

    /// Colors assigned to snakes in sequence.
    #[arg(long = "snake-colors", num_args = 1.., value_parser = parse_color,
          default_values = ["22c55e", "84cc16", "a3e635"])]
    pub snake_colors: Vec<Color>,

    /// Speed of snake head movement along the grid (1 is a calm slither; the
    /// approach from the edge runs faster than the laying).
    #[arg(long = "movement-speed", default_value_t = 1.0, value_parser = parse_positive_float)]
    pub movement_speed: f64,

    /// Number of frames between snake spawns.
    #[arg(long = "spawn-delay", default_value_t = 18, value_parser = parse_non_negative_int)]
    pub spawn_delay: i64,

    /// Symbol used for each snake head.
    #[arg(long = "head-symbol", default_value = "●", value_parser = parse_symbol)]
    pub head_symbol: String,

    /// Visible body length of a snake, in cells (carried characters beyond it ride out of sight).
    #[arg(long = "body-length", default_value_t = 12, value_parser = parse_positive_int)]
    pub body_length: i64,

    /// Color of the flicking tongue.
    #[arg(long = "tongue-color", value_parser = parse_color, default_value = "f43f5e")]
    pub tongue_color: Color,

    /// Space separated, unquoted, list of colors for the final color gradient.
    #[arg(long = "final-gradient-stops", num_args = 1.., value_parser = parse_color,
          default_values = ["22c55e", "84cc16", "fde047"])]
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

/// SnakeIterator.DYNAMIC_NEUTRAL_GRAY.
fn dynamic_neutral_gray() -> Color {
    Color::from_rgb(0x80, 0x80, 0x80)
}

/// Head cells per frame at --movement-speed 1 while laying.
const BASE_PACE: f64 = 0.125;
/// The approach from the edge runs at least this much faster...
const ENTRY_BOOST: f64 = 2.5;
/// ...and fast enough to take at most this many frames on a big canvas.
const ENTRY_FRAMES: f64 = 240.0;
/// Characters per snake above which the pace grows with the load.
const PACE_LOAD: f64 = 110.0;
/// Shades in a snake's body palette, dark to bright.
const SHADES: usize = 24;
/// Base cells per frame for the post-assembly keeper snake flourish.
const KEEPER_BASE_PACE: f64 = 0.42;
/// Target upper bound on flourish frames at --movement-speed 1.0 (keeps huge texts quick).
const KEEPER_MAX_FRAMES: f64 = 620.0;
/// Number of soft fading wake cells behind the keeper snake's tail.
const KEEPER_WAKE_LEN: usize = 5;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Edge {
    Left,
    Right,
    Top,
    Bottom,
}

struct KeeperState {
    head: u32,
    tongue: u32,
    body: Vec<u32>,
    wake: Vec<u32>,
    trail: VecDeque<Coord>,
    route: VecDeque<Coord>,
    started: bool,
    tucking: bool,
    tuck_left: usize,
    done: bool,
    progress: f64,
    pace: f64,
    steps: u64,
    dir: (i64, i64),
    tongue_wait: i64,
    tongue_left: i64,
    head_color: ColorPair,
    palette: Vec<ColorPair>,
    tail_palette: Vec<ColorPair>,
    wake_colors: Vec<ColorPair>,
    taper_syms: [Sym; 3],
}

struct SnakeState {
    head: u32,
    tongue: u32,
    carried: VecDeque<u32>,
    /// Cells the head has stood on, newest (the head's) first; at most the body length.
    trail: VecDeque<Coord>,
    /// The cells still to step on to reach the next target, in order.
    route: VecDeque<Coord>,
    /// Fractional head steps owed.
    progress: f64,
    /// Steps taken so far (anchors the scale pattern to the body).
    steps: u64,
    entering: bool,
    entry_boost: f64,
    horizontal_first: bool,
    /// Last step direction.
    dir: (i64, i64),
    /// Frames to the next tongue flick, and frames left of the current one.
    tongue_wait: i64,
    tongue_left: i64,
    /// Body colors, dark to bright.
    palette: Vec<ColorPair>,
}

pub struct Snake {
    config: SnakeConfig,
    snakes: Vec<SnakeState>,
    /// Snakes not spawned yet (indices into `snakes`, in spawn order).
    pending: VecDeque<usize>,
    active_snakes: Vec<usize>,
    spawn_countdown: i64,
    /// Settle scene per character slot (NONE for characters without one).
    settle: Vec<u32>,
    pace: f64,
    frame: u64,
    tongue_h: Sym,
    tongue_v: Sym,
    /// A full block, and the half blocks shown as one on the approach.
    full: Sym,
    partial: [Sym; 4],
    /// Post-assembly keeper snake flourish (None on tiny canvases/inputs).
    keeper: Option<KeeperState>,
}

impl Snake {
    pub fn new(config: SnakeConfig) -> Self {
        Snake {
            config,
            snakes: Vec::new(),
            pending: VecDeque::new(),
            active_snakes: Vec::new(),
            spawn_countdown: 0,
            settle: Vec::new(),
            pace: BASE_PACE,
            frame: 0,
            tongue_h: Sym(0),
            tongue_v: Sym(0),
            full: Sym(0),
            partial: [Sym(0); 4],
            keeper: None,
        }
    }
}

impl Hooks for Snake {}

fn other(message: String) -> EngineError {
    EngineError::Other(message)
}

fn mix(a: Color, b: Color, t: f64) -> Color {
    let (a, b) = (a.rgb_ints(), b.rgb_ints());
    let t = t.clamp(0.0, 1.0);
    let m = |x: u8, y: u8| (x as f64 + (y as f64 - x as f64) * t).round() as u8;
    Color::from_rgb(m(a.0, b.0), m(a.1, b.1), m(a.2, b.2))
}

fn white() -> Color {
    Color::from_rgb(0xff, 0xff, 0xff)
}

fn black() -> Color {
    Color::from_rgb(0, 0, 0)
}

/// Append the cells of an orthogonal walk from `from` to `to` (excluding
/// `from`, including `to`), with at most one corner.
fn push_leg(route: &mut VecDeque<Coord>, from: Coord, to: Coord, horizontal_first: bool) {
    fn walk_columns(route: &mut VecDeque<Coord>, at: &mut Coord, column: i64) {
        let step = if column > at.column { 1 } else { -1 };
        while at.column != column {
            at.column += step;
            route.push_back(*at);
        }
    }
    let mut at = from;
    if horizontal_first {
        walk_columns(route, &mut at, to.column);
    }
    let step = if to.row > at.row { 1 } else { -1 };
    while at.row != to.row {
        at.row += step;
        route.push_back(at);
    }
    walk_columns(route, &mut at, to.column);
}

impl Snake {
    fn spawn(&mut self, e: &mut Engine, index: usize) {
        let snake = &mut self.snakes[index];
        e.set_visible(snake.head, true);
        self.active_snakes.push(index);
    }

    /// Plan the route from the head's cell to the next carried character's place.
    fn plan(e: &Engine, snake: &mut SnakeState) {
        let target = e.input_coord(snake.carried[0]);
        let from = snake.trail[0];
        snake.route.clear();
        push_leg(&mut snake.route, from, target, snake.horizontal_first);
        if snake.route.is_empty() {
            snake.route.push_back(target);
        }
        snake.horizontal_first = !snake.horizontal_first;
    }

    /// The head stands on its target: lay the front character there.
    fn deposit(&mut self, e: &mut Engine, index: usize) {
        let snake = &mut self.snakes[index];
        let slot = snake.carried.pop_front().expect("deposit: empty snake");
        snake.entering = false;
        let input = e.input_coord(slot);
        e.set_coordinate(slot, input);
        e.set_layer(slot, 0);
        e.set_visible(slot, true);
        let scene = self.settle[slot as usize];
        if scene != NONE {
            e.activate_scene(self, slot, scene);
        }
        e.active_insert(slot);
        let snake = &mut self.snakes[index];
        if !snake.carried.is_empty() {
            Self::plan(e, snake);
        }
    }

    /// Move one snake by the steps it is owed this frame. False when it is done.
    fn advance(&mut self, e: &mut Engine, index: usize) -> bool {
        let body_length = self.config.body_length.max(1) as usize;
        let boost = if self.snakes[index].entering {
            self.snakes[index].entry_boost
        } else {
            1.0
        };
        self.snakes[index].progress += self.pace * boost;
        while self.snakes[index].progress >= 1.0 {
            let snake = &mut self.snakes[index];
            snake.progress -= 1.0;
            let Some(cell) = snake.route.pop_front() else {
                break;
            };
            let previous = snake.trail[0];
            snake.dir = (
                (cell.column - previous.column).signum(),
                (cell.row - previous.row).signum(),
            );
            snake.trail.push_front(cell);
            snake.trail.truncate(body_length + 1);
            snake.steps += 1;
            e.set_coordinate(snake.head, cell);
            if snake.route.is_empty() {
                self.deposit(e, index);
                if self.snakes[index].carried.is_empty() {
                    let snake = &self.snakes[index];
                    e.set_visible(snake.head, false);
                    e.set_visible(snake.tongue, false);
                    return false;
                }
            }
        }
        self.dress(e, index);
        true
    }

    /// Lay the visible body along the trail and shade it; flick the tongue.
    fn dress(&mut self, e: &mut Engine, index: usize) {
        let body_length = self.config.body_length.max(1) as usize;
        let frame = self.frame;
        let (tongue_h, tongue_v) = (self.tongue_h, self.tongue_v);
        let (full, partial) = (self.full, self.partial);
        let tongue_color = self.config.tongue_color;
        let snake = &mut self.snakes[index];
        // segment i sits on trail[i + 1]: the cell the head left i + 1 steps ago
        let shown = snake
            .carried
            .len()
            .min(body_length)
            .min(snake.trail.len() - 1);
        for i in 0..shown {
            let slot = snake.carried[i];
            let cell = snake.trail[i + 1];
            if e.coord(slot) != cell {
                e.set_coordinate(slot, cell);
            }
            if !e.is_visible(slot) {
                e.set_visible(slot, true);
            }
            let taper = i as f64 / body_length as f64;
            let scale = if (snake.steps + i as u64) % 2 == 0 {
                0.0
            } else {
                -0.1
            };
            let ripple = 0.1 * ((i as f64) * 0.8 - frame as f64 * 0.16).sin();
            let shade = (0.92 - 0.55 * taper + scale + ripple).clamp(0.0, 1.0);
            let k = (shade * (SHADES - 1) as f64).round() as usize;
            let colors = snake.palette[k];
            // on the approach a body of half blocks would read as a dotted
            // line: show them whole until the snake starts laying
            let sym = if snake.entering && partial.contains(&e.input_sym(slot)) {
                Some(full)
            } else {
                None
            };
            e.set_appearance(slot, sym, Some(colors));
        }
        // the carried character under the head and the ones out of sight
        for i in shown..snake.carried.len().min(body_length + 1) {
            let slot = snake.carried[i];
            if e.is_visible(slot) {
                e.set_visible(slot, false);
            }
        }
        // the tongue: two quick flicks every so often, once the head is moving
        if snake.tongue_wait > 0 {
            snake.tongue_wait -= 1;
        } else if snake.tongue_left == 0 {
            snake.tongue_left = 14;
            snake.tongue_wait = e.rng.randint(70, 170);
        }
        let mut show = false;
        if snake.tongue_left > 0 {
            snake.tongue_left -= 1;
            show = snake.dir != (0, 0) && !(5..9).contains(&snake.tongue_left);
        }
        if show {
            let at = snake.trail[0];
            let tip = Coord::new(at.column + snake.dir.0, at.row + snake.dir.1);
            let sym = if snake.dir.0 != 0 { tongue_h } else { tongue_v };
            e.set_coordinate(snake.tongue, tip);
            e.set_appearance(
                snake.tongue,
                Some(sym),
                Some(ColorPair::new(Some(tongue_color), None)),
            );
        }
        if e.is_visible(snake.tongue) != show {
            e.set_visible(snake.tongue, show);
        }
    }

    /// The settle scene: a bright glint of the snake's color fading into the final one.
    fn build_settle_scene(
        &mut self,
        e: &mut Engine,
        slot: u32,
        snake_color: Color,
        final_colors: ColorPair,
    ) -> Result<(), String> {
        let sym = e.input_sym(slot);
        let glint = mix(snake_color, white(), 0.6);
        let scene = e.scene_new(slot, Name::NONE, false, None, None);
        if e.existing_color_handling() == ExistingColorHandling::Dynamic {
            let (fg, bg) = (final_colors.fg_color, final_colors.bg_color);
            if fg.is_some() || bg.is_some() {
                let fg = fg
                    .map(|c| {
                        Gradient::with_steps(&[glint, snake_color, c], 5, false).map(|g| g.spectrum)
                    })
                    .transpose()?;
                let background = e.config.terminal_background_color;
                let bg = bg
                    .map(|c| Gradient::with_steps(&[background, c], 10, false).map(|g| g.spectrum))
                    .transpose()?;
                e.apply_gradient(scene, &[sym], 3, fg.as_deref(), bg.as_deref())?;
            } else {
                let fg =
                    Gradient::with_steps(&[glint, snake_color, dynamic_neutral_gray()], 4, false)?;
                e.apply_gradient(scene, &[sym], 3, Some(&fg.spectrum), None)?;
                e.add_frame(scene, sym, 2, Some(ColorPair::default()), 0)?;
            }
        } else {
            let final_fg = final_colors.fg_color.unwrap_or(snake_color);
            let fg = Gradient::with_steps(&[glint, snake_color, final_fg], 5, false)?;
            e.apply_gradient(scene, &[sym], 3, Some(&fg.spectrum), None)?;
        }
        self.settle[slot as usize] = scene;
        Ok(())
    }

    fn keeper_active(&self) -> bool {
        self.keeper.as_ref().is_some_and(|k| !k.done)
    }

    fn hide_keeper(e: &mut Engine, k: &KeeperState) {
        if e.is_visible(k.head) {
            e.set_visible(k.head, false);
        }
        if e.is_visible(k.tongue) {
            e.set_visible(k.tongue, false);
        }
        for &slot in &k.body {
            if e.is_visible(slot) {
                e.set_visible(slot, false);
            }
        }
        for &slot in &k.wake {
            if e.is_visible(slot) {
                e.set_visible(slot, false);
            }
        }
    }

    fn advance_keeper(&mut self, e: &mut Engine) {
        let frame = self.frame;
        let (tongue_h, tongue_v, full) = (self.tongue_h, self.tongue_v, self.full);
        let tongue_color = self.config.tongue_color;
        let Some(k) = self.keeper.as_mut() else {
            return;
        };
        if k.done {
            return;
        }
        if !k.started {
            k.started = true;
            e.set_visible(k.head, true);
        }
        let body_len = k.body.len();
        let wake_len = k.wake.len();
        let total_chain = body_len + wake_len;
        k.progress += k.pace;
        while k.progress >= 1.0 {
            k.progress -= 1.0;
            if !k.tucking {
                if let Some(cell) = k.route.pop_front() {
                    let previous = k.trail[0];
                    k.dir = (
                        (cell.column - previous.column).signum(),
                        (cell.row - previous.row).signum(),
                    );
                    k.trail.push_front(cell);
                    k.trail.truncate(total_chain + 1);
                    k.steps += 1;
                    e.set_coordinate(k.head, cell);
                    // Trigger a cheeky tongue flick as it dives into the finale
                    if k.route.len() == 16 && k.tongue_left == 0 {
                        k.tongue_wait = 0;
                    }
                    if k.route.is_empty() {
                        k.tucking = true;
                        k.tuck_left = total_chain;
                        e.set_visible(k.head, false);
                        e.set_visible(k.tongue, false);
                    }
                } else {
                    k.tucking = true;
                    k.tuck_left = total_chain;
                    e.set_visible(k.head, false);
                    e.set_visible(k.tongue, false);
                }
            } else if k.tuck_left > 0 {
                k.tuck_left -= 1;
                k.steps += 1;
                if k.tuck_left == 0 {
                    k.done = true;
                    Self::hide_keeper(e, k);
                    return;
                }
            } else {
                k.done = true;
                Self::hide_keeper(e, k);
                return;
            }
        }

        let tuck_hidden = if k.tucking {
            total_chain - k.tuck_left
        } else {
            0
        };

        // Render keeper body segments along the trail with banded scales and tapered tail.
        for i in 0..body_len {
            let slot = k.body[i];
            if i < tuck_hidden {
                if e.is_visible(slot) {
                    e.set_visible(slot, false);
                }
                continue;
            }
            let trail_idx = i + 1 - tuck_hidden;
            if trail_idx >= k.trail.len() {
                if e.is_visible(slot) {
                    e.set_visible(slot, false);
                }
                continue;
            }
            let cell = k.trail[trail_idx];
            if e.coord(slot) != cell {
                e.set_coordinate(slot, cell);
            }
            if !e.is_visible(slot) {
                e.set_visible(slot, true);
            }
            let taper = i as f64 / body_len.max(1) as f64;
            let scale = if (k.steps + i as u64) % 2 == 0 {
                0.04
            } else {
                -0.10
            };
            let ripple = 0.12 * ((i as f64) * 0.75 - frame as f64 * 0.18).sin();
            let shade = (0.94 - 0.52 * taper + scale + ripple).clamp(0.0, 1.0);
            let idx = (shade * (SHADES - 1) as f64).round() as usize;
            let tail_from_end = body_len - 1 - i;
            let (sym, colors) = if tail_from_end < 3 {
                (k.taper_syms[2 - tail_from_end], k.tail_palette[idx])
            } else {
                (full, k.palette[idx])
            };
            e.set_appearance(slot, Some(sym), Some(colors));
        }

        // Render soft fading emerald wake behind the tail tip.
        let wake_sym = k.taper_syms[2];
        for j in 0..wake_len {
            let slot = k.wake[j];
            let chain_idx = body_len + j;
            if chain_idx < tuck_hidden {
                if e.is_visible(slot) {
                    e.set_visible(slot, false);
                }
                continue;
            }
            let trail_idx = chain_idx + 1 - tuck_hidden;
            if trail_idx >= k.trail.len() {
                if e.is_visible(slot) {
                    e.set_visible(slot, false);
                }
                continue;
            }
            let cell = k.trail[trail_idx];
            if e.coord(slot) != cell {
                e.set_coordinate(slot, cell);
            }
            if !e.is_visible(slot) {
                e.set_visible(slot, true);
            }
            e.set_appearance(slot, Some(wake_sym), Some(k.wake_colors[j]));
        }

        // Keep head luminous and flick the forked tongue while patrolling.
        if !k.tucking {
            e.set_appearance(k.head, None, Some(k.head_color));
            if k.tongue_wait > 0 {
                k.tongue_wait -= 1;
            } else if k.tongue_left == 0 {
                k.tongue_left = 14;
                k.tongue_wait = e.rng.randint(24, 52);
            }
            let mut show = false;
            if k.tongue_left > 0 {
                k.tongue_left -= 1;
                show = k.dir != (0, 0) && !(5..9).contains(&k.tongue_left);
            }
            if show {
                let at = k.trail[0];
                let tip = Coord::new(at.column + k.dir.0, at.row + k.dir.1);
                let sym = if k.dir.0 != 0 { tongue_h } else { tongue_v };
                e.set_coordinate(k.tongue, tip);
                e.set_appearance(
                    k.tongue,
                    Some(sym),
                    Some(ColorPair::new(Some(tongue_color), None)),
                );
            }
            if e.is_visible(k.tongue) != show {
                e.set_visible(k.tongue, show);
            }
        }
    }
}

/// Find the leftmost enclosed hollow cavity inside the visible text (e.g. the
/// interior of the "O" in OMARCHY) using a bounded BFS flood-fill.
fn find_leftmost_hole(
    occupied: &HashSet<Coord>,
    min_x: i64,
    max_x: i64,
    min_y: i64,
    max_y: i64,
) -> Option<(i64, i64, i64, i64)> {
    let w = (max_x - min_x + 1) as usize;
    let h = (max_y - min_y + 1) as usize;
    if w < 3 || h < 3 {
        return None;
    }
    let gw = w + 2;
    let gh = h + 2;
    let mut occ = vec![false; gw * gh];
    for &c in occupied {
        if c.column >= min_x && c.column <= max_x && c.row >= min_y && c.row <= max_y {
            let gx = (c.column - min_x + 1) as usize;
            let gy = (c.row - min_y + 1) as usize;
            occ[gy * gw + gx] = true;
        }
    }
    let mut outside = vec![false; gw * gh];
    let mut queue = VecDeque::new();
    outside[0] = true;
    queue.push_back((0usize, 0usize));
    while let Some((x, y)) = queue.pop_front() {
        let neighbors = [
            (x.wrapping_sub(1), y),
            (x + 1, y),
            (x, y.wrapping_sub(1)),
            (x, y + 1),
        ];
        for (nx, ny) in neighbors {
            if nx < gw && ny < gh {
                let idx = ny * gw + nx;
                if !outside[idx] && !occ[idx] {
                    outside[idx] = true;
                    queue.push_back((nx, ny));
                }
            }
        }
    }
    let mut visited = vec![false; gw * gh];
    let max_left_x = min_x + (w as i64) / 3;
    let mut best: Option<(i64, usize, (i64, i64, i64, i64))> = None;
    for gy in 1..=h {
        for gx in 1..=w {
            let start_idx = gy * gw + gx;
            if occ[start_idx] || outside[start_idx] || visited[start_idx] {
                continue;
            }
            let mut comp_q = VecDeque::new();
            visited[start_idx] = true;
            comp_q.push_back((gx, gy));
            let mut area = 0usize;
            let mut hx0 = i64::MAX;
            let mut hx1 = i64::MIN;
            let mut hy0 = i64::MAX;
            let mut hy1 = i64::MIN;
            while let Some((cx, cy)) = comp_q.pop_front() {
                area += 1;
                let wx = min_x + cx as i64 - 1;
                let wy = min_y + cy as i64 - 1;
                hx0 = hx0.min(wx);
                hx1 = hx1.max(wx);
                hy0 = hy0.min(wy);
                hy1 = hy1.max(wy);
                for (nx, ny) in [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)] {
                    let nidx = ny * gw + nx;
                    if !occ[nidx] && !outside[nidx] && !visited[nidx] {
                        visited[nidx] = true;
                        comp_q.push_back((nx, ny));
                    }
                }
            }
            if area >= 2 && hx0 <= max_left_x {
                let better = match best {
                    None => true,
                    Some((best_x, best_area, _)) => {
                        hx0 < best_x || (hx0 == best_x && area > best_area)
                    }
                };
                if better {
                    best = Some((hx0, area, (hx0, hx1, hy0, hy1)));
                }
            }
        }
    }
    best.map(|(_, _, bounds)| bounds)
}

fn push_ortho_step(
    route: &mut VecDeque<Coord>,
    cur: &mut Coord,
    to: Coord,
    horizontal_first: bool,
) {
    if *cur == to {
        return;
    }
    push_leg(route, *cur, to, horizontal_first);
    *cur = to;
}

/// Build the skyline-hugging clockwise patrol around the visible text,
/// emerging from and slipping back into the leftmost enclosed hollow (the "O"
/// on OMARCHY) when one exists.
fn build_keeper_route(e: &Engine, characters: &[u32]) -> Option<(Coord, VecDeque<Coord>)> {
    let canvas = &e.canvas;
    if characters.len() < 4 || canvas.width < 10 || canvas.height < 4 {
        return None;
    }
    let mut occupied = HashSet::new();
    let mut min_x = i64::MAX;
    let mut max_x = i64::MIN;
    let mut min_y = i64::MAX;
    let mut max_y = i64::MIN;
    for &slot in characters {
        let c = e.input_coord(slot);
        if canvas.coord_is_in_canvas(c) {
            occupied.insert(c);
            min_x = min_x.min(c.column);
            max_x = max_x.max(c.column);
            min_y = min_y.min(c.row);
            max_y = max_y.max(c.row);
        }
    }
    if occupied.len() < 4 || max_x <= min_x {
        return None;
    }
    let w = (max_x - min_x + 1) as usize;
    let mut raw_top = vec![None::<i64>; w];
    let mut raw_bot = vec![None::<i64>; w];
    for &c in &occupied {
        let i = (c.column - min_x) as usize;
        raw_top[i] = Some(raw_top[i].map_or(c.row, |t| t.max(c.row)));
        raw_bot[i] = Some(raw_bot[i].map_or(c.row, |b| b.min(c.row)));
    }
    // Nearest occupied neighbor top/bottom for gentle 1-cell dips in inter-letter gaps.
    let mut left_top = vec![max_y; w];
    let mut right_top = vec![max_y; w];
    let mut left_bot = vec![min_y; w];
    let mut right_bot = vec![min_y; w];
    let mut last_t = max_y;
    let mut last_b = min_y;
    for i in 0..w {
        if let Some(t) = raw_top[i] {
            last_t = t;
        }
        if let Some(b) = raw_bot[i] {
            last_b = b;
        }
        left_top[i] = last_t;
        left_bot[i] = last_b;
    }
    last_t = max_y;
    last_b = min_y;
    for i in (0..w).rev() {
        if let Some(t) = raw_top[i] {
            last_t = t;
        }
        if let Some(b) = raw_bot[i] {
            last_b = b;
        }
        right_top[i] = last_t;
        right_bot[i] = last_b;
    }
    let mut top_y = vec![0i64; w];
    let mut bot_y = vec![0i64; w];
    // Leave a 1-cell breathing gap between the letters and the patrolling snake
    // when canvas margin allows, so its silhouette, scales, and tongue pop clearly.
    let v_pad = if canvas.height >= (max_y - min_y + 1) + 4 {
        2
    } else {
        1
    };
    let h_pad = if canvas.width >= (max_x - min_x + 1) + 4 {
        2
    } else {
        1
    };
    for i in 0..w {
        top_y[i] = match raw_top[i] {
            Some(t) => (t + v_pad).min(canvas.top),
            None => (left_top[i].min(right_top[i]) + v_pad - 1).clamp(canvas.bottom, canvas.top),
        };
        bot_y[i] = match raw_bot[i] {
            Some(b) => (b - v_pad).max(canvas.bottom),
            None => (left_bot[i].max(right_bot[i]) - v_pad + 1).clamp(canvas.bottom, canvas.top),
        };
    }

    let left_col = (min_x - h_pad).max(canvas.left);
    let right_col = (max_x + h_pad).min(canvas.right);
    let walk_top_lr = |route: &mut VecDeque<Coord>, cur: &mut Coord, x0: i64, x1: i64| {
        for x in x0..=x1 {
            let ny = top_y[(x - min_x) as usize];
            let h_first = ny <= cur.row;
            push_ortho_step(route, cur, Coord::new(x, ny), h_first);
        }
    };
    let walk_bot_rl = |route: &mut VecDeque<Coord>, cur: &mut Coord, x_hi: i64, x_lo: i64| {
        for x in (x_lo..=x_hi).rev() {
            let ny = bot_y[(x - min_x) as usize];
            let h_first = ny >= cur.row;
            push_ortho_step(route, cur, Coord::new(x, ny), h_first);
        }
    };

    let mut route = VecDeque::new();
    let start = if let Some((hx0, hx1, hy0, hy1)) =
        find_leftmost_hole(&occupied, min_x, max_x, min_y, max_y)
    {
        let cx = (hx0 + hx1) / 2;
        let cy = (hy0 + hy1) / 2;
        let start = Coord::new(cx, hy0);
        let mut cur = start;
        // Emerge upward out of the hollow "O" onto the top skyline.
        push_ortho_step(
            &mut route,
            &mut cur,
            Coord::new(cx, top_y[(cx - min_x) as usize]),
            false,
        );
        // Patrol clockwise along the top contour (over M's crown), down the right,
        // along the bottom contour (under R's leg), up the left, and back to O.
        walk_top_lr(&mut route, &mut cur, cx, max_x);
        let r = cur.row;
        push_ortho_step(&mut route, &mut cur, Coord::new(right_col, r), true);
        push_ortho_step(
            &mut route,
            &mut cur,
            Coord::new(right_col, bot_y[w - 1]),
            false,
        );
        walk_bot_rl(&mut route, &mut cur, max_x, min_x);
        let r = cur.row;
        push_ortho_step(&mut route, &mut cur, Coord::new(left_col, r), true);
        push_ortho_step(&mut route, &mut cur, Coord::new(left_col, top_y[0]), false);
        walk_top_lr(&mut route, &mut cur, min_x, cx);
        // Slip back under the rim into the "O" and curl inside its hollow.
        push_ortho_step(&mut route, &mut cur, Coord::new(hx1, hy1), true);
        push_ortho_step(&mut route, &mut cur, Coord::new(hx1, hy0), false);
        push_ortho_step(&mut route, &mut cur, Coord::new(hx0, hy0), true);
        push_ortho_step(&mut route, &mut cur, Coord::new(hx0, hy1), false);
        push_ortho_step(&mut route, &mut cur, Coord::new(cx, cy), true);
        start
    } else {
        let start = Coord::new(left_col, top_y[0]);
        let mut cur = start;
        walk_top_lr(&mut route, &mut cur, min_x, max_x);
        let r = cur.row;
        push_ortho_step(&mut route, &mut cur, Coord::new(right_col, r), true);
        push_ortho_step(
            &mut route,
            &mut cur,
            Coord::new(right_col, bot_y[w - 1]),
            false,
        );
        walk_bot_rl(&mut route, &mut cur, max_x, min_x);
        let r = cur.row;
        push_ortho_step(&mut route, &mut cur, Coord::new(left_col, r), true);
        push_ortho_step(&mut route, &mut cur, Coord::new(left_col, top_y[0]), false);
        start
    };

    if route.is_empty() {
        return None;
    }
    Some((start, route))
}

/// Order a band's characters as a row-by-row serpentine: rows from the top
/// (or the bottom), the first row left to right (or right to left), then
/// alternating.
fn serpentine(e: &Engine, band: &[u32], top_down: bool, left_first: bool) -> Vec<u32> {
    let mut sorted = band.to_vec();
    sorted.sort_by_key(|&slot| {
        let c = e.input_coord(slot);
        (if top_down { -c.row } else { c.row }, c.column)
    });
    let mut out = Vec::with_capacity(sorted.len());
    let mut forward = left_first;
    let mut i = 0;
    while i < sorted.len() {
        let row = e.input_coord(sorted[i]).row;
        let mut j = i;
        while j < sorted.len() && e.input_coord(sorted[j]).row == row {
            j += 1;
        }
        let start = out.len();
        out.extend_from_slice(&sorted[i..j]);
        if !forward {
            out[start..].reverse();
        }
        forward = !forward;
        i = j;
    }
    out
}

impl Effect for Snake {
    fn build(&mut self, e: &mut Engine) -> Result<(), EngineError> {
        let config = self.config.clone();
        // columns from the left, each from the top
        let mut characters = e.get_characters(
            CharacterFilter::default(),
            CharacterSort::TopToBottomLeftToRight,
        );
        characters.sort_by_key(|&slot| {
            let c = e.input_coord(slot);
            (c.column, -c.row)
        });
        let snake_count = (config.snake_count.max(1) as usize).min(characters.len());
        if snake_count == 0 || config.snake_colors.is_empty() {
            return Ok(());
        }
        self.settle = vec![NONE; e.char_count()];
        let per_snake = characters.len() as f64 / snake_count as f64;
        self.pace = BASE_PACE * config.movement_speed * (per_snake / PACE_LOAD).max(1.0);
        self.tongue_h = e.sym("-");
        self.tongue_v = e.sym("¦");
        self.full = e.sym("█");
        self.partial = [e.sym("▀"), e.sym("▄"), e.sym("▌"), e.sym("▐")];

        let canvas = e.canvas.clone();
        let dynamic = e.existing_color_handling() == ExistingColorHandling::Dynamic;
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

        let head_sym = e.sym(&config.head_symbol);
        let (group_size, remainder) = (
            characters.len() / snake_count,
            characters.len() % snake_count,
        );
        let (left, right, bottom, top) = (canvas.left, canvas.right, canvas.bottom, canvas.top);
        let mut start = 0;
        for snake_index in 0..snake_count {
            let size = group_size + usize::from(snake_index < remainder);
            let band = &characters[start..start + size];
            start += size;
            let edge = if snake_index == 0 {
                Edge::Left
            } else if snake_index == snake_count - 1 {
                Edge::Right
            } else if snake_index % 2 == 1 {
                Edge::Top
            } else {
                Edge::Bottom
            };
            let group = match edge {
                Edge::Left | Edge::Top => serpentine(e, band, true, true),
                Edge::Right | Edge::Bottom => serpentine(e, band, false, false),
            };
            let target = e.input_coord(group[0]);
            // a random point on the edge, then a random bend inside the
            // canvas between there and the first target
            let random_between = |e: &mut Engine, a: i64, b: i64| e.rng.randint(a.min(b), a.max(b));
            let spawn = match edge {
                Edge::Left => Coord::new(left - 1, random_between(e, bottom, top)),
                Edge::Right => Coord::new(right + 1, random_between(e, bottom, top)),
                Edge::Top => Coord::new(random_between(e, left, right), top + 1),
                Edge::Bottom => Coord::new(random_between(e, left, right), bottom - 1),
            };
            let bend = match edge {
                Edge::Left | Edge::Right => Coord::new(
                    random_between(e, spawn.column, target.column),
                    random_between(e, bottom, top),
                ),
                Edge::Top | Edge::Bottom => Coord::new(
                    random_between(e, left, right),
                    random_between(e, spawn.row, target.row),
                ),
            };
            let entry_horizontal = matches!(edge, Edge::Left | Edge::Right);
            let mut route = VecDeque::new();
            push_leg(&mut route, spawn, bend, entry_horizontal);
            let from = route.back().copied().unwrap_or(spawn);
            push_leg(&mut route, from, target, entry_horizontal);
            if route.is_empty() {
                route.push_back(target);
            }

            let color = config.snake_colors[snake_index % config.snake_colors.len()];
            let head_color = mix(color, white(), 0.45);
            let layer = 2 + snake_index as i32 * 3;
            let head = e.add_character_sym(head_sym, spawn);
            e.set_coordinate(head, spawn);
            e.set_appearance(
                head,
                Some(head_sym),
                Some(ColorPair::new(Some(head_color), None)),
            );
            e.set_layer(head, layer + 1);
            let tongue = e.add_character_sym(self.tongue_h, spawn);
            e.set_layer(tongue, layer + 2);
            e.set_visible(tongue, false);
            if self.settle.len() < e.char_count() {
                self.settle.resize(e.char_count(), NONE);
            }
            for &slot in &group {
                e.set_coordinate(slot, spawn);
                e.set_appearance(slot, None, Some(ColorPair::new(Some(color), None)));
                e.set_layer(slot, layer);
                e.set_visible(slot, false);
                let final_colors = if dynamic {
                    ColorPair::new(e.input_fg(slot), e.input_bg(slot))
                } else {
                    let input = e.input_coord(slot);
                    ColorPair::new(
                        Some(final_mapping.get(&input).copied().unwrap_or(fallback)),
                        None,
                    )
                };
                self.build_settle_scene(e, slot, color, final_colors)
                    .map_err(other)?;
            }
            // dark to the snake's color at 80 %, then toward white
            let palette = (0..SHADES)
                .map(|k| {
                    let f = k as f64 / (SHADES - 1) as f64;
                    let c = if f < 0.8 {
                        mix(black(), color, 0.3 + 0.7 * f / 0.8)
                    } else {
                        mix(color, white(), (f - 0.8) / 0.2 * 0.4)
                    };
                    ColorPair::new(Some(c), None)
                })
                .collect();
            let tongue_wait = e.rng.randint(20, 120);
            let entry_len = route.len() as f64;
            self.snakes.push(SnakeState {
                head,
                tongue,
                carried: group.into(),
                trail: VecDeque::from([spawn]),
                route,
                progress: 0.0,
                steps: 0,
                entering: true,
                entry_boost: ENTRY_BOOST.max(entry_len / (ENTRY_FRAMES * self.pace)),
                horizontal_first: !entry_horizontal,
                dir: (0, 0),
                tongue_wait,
                tongue_left: 0,
                palette,
            });
        }
        self.pending = (0..self.snakes.len()).collect();
        self.active_snakes.clear();
        self.spawn_countdown = 0;
        self.frame = 0;

        // Build the post-assembly keeper snake flourish.
        self.keeper = if let Some((start, route)) = build_keeper_route(e, &characters) {
            let body_len = config.body_length.clamp(6, 14) as usize;
            let total_steps = (route.len() + body_len + KEEPER_WAKE_LEN) as f64;
            let keeper_pace =
                KEEPER_BASE_PACE.max(total_steps / KEEPER_MAX_FRAMES) * config.movement_speed;
            let primary = config.snake_colors[0];
            let accent = *config
                .final_gradient_stops
                .last()
                .unwrap_or(&primary);
            let head_fg = mix(mix(primary, accent, 0.35), white(), 0.72);
            let head_bg = mix(black(), primary, 0.28);
            let head_color = ColorPair::new(Some(head_fg), Some(head_bg));

            let palette: Vec<ColorPair> = (0..SHADES)
                .map(|k| {
                    let f = k as f64 / (SHADES - 1) as f64;
                    let c = if f < 0.68 {
                        mix(black(), primary, 0.34 + 0.66 * f / 0.68)
                    } else {
                        mix(primary, mix(accent, white(), 0.30), (f - 0.68) / 0.32 * 0.78)
                    };
                    ColorPair::new(Some(c), None)
                })
                .collect();
            let tail_bg = mix(black(), primary, 0.10);
            let tail_palette: Vec<ColorPair> = palette
                .iter()
                .map(|cp| ColorPair::new(cp.fg_color, Some(tail_bg)))
                .collect();
            let wake_colors: Vec<ColorPair> = (0..KEEPER_WAKE_LEN)
                .map(|j| {
                    let frac = 1.0 - (j as f64 / KEEPER_WAKE_LEN as f64);
                    let fg = mix(black(), primary, 0.30 * frac * frac + 0.05);
                    ColorPair::new(Some(fg), None)
                })
                .collect();

            // Place keeper layers strictly below layer 0 so input letters remain
            // untouched heroes and the snake slips cleanly underneath the "O" rim.
            let head = e.add_character_sym(head_sym, start);
            e.set_coordinate(head, start);
            e.set_appearance(head, Some(head_sym), Some(head_color));
            e.set_layer(head, -1);
            e.set_visible(head, false);

            let tongue = e.add_character_sym(self.tongue_h, start);
            e.set_coordinate(tongue, start);
            e.set_layer(tongue, -1);
            e.set_visible(tongue, false);

            let mut body = Vec::with_capacity(body_len);
            for _ in 0..body_len {
                let slot = e.add_character_sym(self.full, start);
                e.set_coordinate(slot, start);
                e.set_layer(slot, -2);
                e.set_visible(slot, false);
                body.push(slot);
            }

            let taper_syms = [e.sym("▓"), e.sym("▒"), e.sym("░")];
            let mut wake = Vec::with_capacity(KEEPER_WAKE_LEN);
            for _ in 0..KEEPER_WAKE_LEN {
                let slot = e.add_character_sym(taper_syms[2], start);
                e.set_coordinate(slot, start);
                e.set_layer(slot, -3);
                e.set_visible(slot, false);
                wake.push(slot);
            }

            let tongue_wait = e.rng.randint(12, 34);
            Some(KeeperState {
                head,
                tongue,
                body,
                wake,
                trail: VecDeque::from([start]),
                route,
                started: false,
                tucking: false,
                tuck_left: 0,
                done: false,
                progress: 0.0,
                pace: keeper_pace,
                steps: 0,
                dir: (0, 1),
                tongue_wait,
                tongue_left: 0,
                head_color,
                palette,
                tail_palette,
                wake_colors,
                taper_syms,
            })
        } else {
            None
        };
        Ok(())
    }

    fn next_frame(&mut self, e: &mut Engine) -> bool {
        if self.pending.is_empty()
            && self.active_snakes.is_empty()
            && e.active_is_empty()
            && !self.keeper_active()
        {
            return false;
        }
        self.frame += 1;
        e.update(self);
        let mut i = 0;
        while i < self.active_snakes.len() {
            let index = self.active_snakes[i];
            if self.advance(e, index) {
                i += 1;
            } else {
                self.active_snakes.remove(i);
            }
        }
        if self.spawn_countdown > 0 {
            self.spawn_countdown -= 1;
        } else if !self.pending.is_empty() {
            if self.config.spawn_delay == 0 {
                while let Some(index) = self.pending.pop_front() {
                    self.spawn(e, index);
                }
            } else {
                let index = self.pending.pop_front().unwrap();
                self.spawn(e, index);
                self.spawn_countdown = self.config.spawn_delay;
            }
        } else if self.active_snakes.is_empty() && self.keeper_active() {
            self.advance_keeper(e);
        }
        true
    }
}
