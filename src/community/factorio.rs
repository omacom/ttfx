//! factorio: a Factorio factory builds the text. A conveyor belt runs under
//! the text, gantries ride a rail above it, and each gantry's inserter arm
//! lifts the characters off the belt one by one: the character rises up the
//! arm glowing, lands on its blueprint dot (spark, yellow, orange) and cools
//! to copper and steel. Once built, the factory comes online: the status
//! beacon locks to green with an ONLINE readout, electric current pulses
//! surge along the connected strokes of the letters like circuit traces while
//! the conveyor keeps ticking underneath, and then the line decelerates and
//! powers down cleanly to leave the finished text.
//!
//! Original effect by Chris AtLee (@catlee), https://github.com/catlee/ttfx, MIT.
//! (`plugins/ttfx-effect-factorio`, a Python frame-protocol plugin adapted
//! from the omarchy-factorio-theme screensaver.)
//!
//! Port notes: the original drew its own frames (fixed OMARCHY glyphs on
//! empty input, else the input in reading order with one inserter that jumps
//! from cell to cell). Here the input characters themselves are built at
//! their laid-out positions and any text works. The text is split into
//! column bands at the blank columns between glyphs, one gantry per band, so
//! each gantry builds whole letters; by default it works column by column,
//! top down, so a stream of characters rises up its arm while it moves along.
//! Every placement is scheduled in `build` (launch and landing frames, the
//! gantry's column per frame), so the run length is known up front. Motion
//! speeds follow the frame rate. The decor (belt, rails, arms, items, lights)
//! is drawn with added characters on layers: blueprint dots (0) < belt, rails
//! and arms (1) < placed characters and trolleys (2) < rising characters and
//! the feed spark (3), so an arm passes over empty and unbuilt cells only, as
//! in the original. When there is no room below the text the belt goes above
//! it; with no room at all it runs along the canvas bottom.
//!
//! Every frame is set directly (no scenes): the per-frame cost is the belt
//! width plus the arms and the characters in flight plus the cells cooling.

use std::cmp::Reverse;
use std::collections::{BinaryHeap, HashMap, VecDeque};

use clap::Args;

use crate::cli::parse_color;
use crate::effects::common::parse_non_negative_int;
use crate::engine::animation::ExistingColorHandling;
use crate::engine::error::EngineError;
use crate::fx::run::Effect;
use crate::fx::visual::{VisualInfo, BOLD, HAS_COLORS};
use crate::fx::{Engine, Hooks, Sym, Visual};
use crate::utils::geometry::Coord;
use crate::utils::graphics::Color;

/// The order each gantry builds its band in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BuildOrder {
    /// Column by column, left to right, the far end of each column first.
    Columns,
    /// Row by row, left to right (the original's order for supplied text).
    Reading,
    /// Along connected strokes, depth first (the original's wordmark order).
    Trace,
    /// Shuffled (seeded).
    Random,
}

fn parse_build_order(s: &str) -> Result<BuildOrder, String> {
    match s {
        "columns" => Ok(BuildOrder::Columns),
        "reading" => Ok(BuildOrder::Reading),
        "trace" => Ok(BuildOrder::Trace),
        "random" => Ok(BuildOrder::Random),
        _ => Err(format!(
            "invalid build order: '{s}' (expected columns, reading, trace or random)"
        )),
    }
}

#[derive(Args, Debug, Clone)]
pub struct FactorioConfig {
    /// Order the characters are built in: columns (column by column, top down), reading (row by row), trace (along connected strokes) or random.
    #[arg(long = "build-order", default_value = "columns", value_parser = parse_build_order)]
    pub build_order: BuildOrder,

    /// Number of gantries building side by side (at most), each in its own column band, split between glyphs where possible. 0 picks one per 70 characters (at most one per 8 columns).
    #[arg(long = "inserters", default_value_t = 0, value_parser = parse_non_negative_int)]
    pub inserters: i64,

    /// Frames between two characters leaving the belt on one gantry. 0 picks 1/15 s, shortened for very large texts.
    #[arg(long = "place-delay", default_value_t = 0, value_parser = parse_non_negative_int)]
    pub place_delay: i64,

    /// Frames a character takes to rise one row up the arm. 0 picks 1/60 s.
    #[arg(long = "lift-frames", default_value_t = 0, value_parser = parse_non_negative_int)]
    pub lift_frames: i64,

    /// Frames a placed character takes to cool from spark through yellow and orange to its final color. 0 picks 1/5 s.
    #[arg(long = "cool-frames", default_value_t = 0, value_parser = parse_non_negative_int)]
    pub cool_frames: i64,

    /// Frames the finished factory runs (circuit pulses over the text, conveyor ticking, green online status, then power down) before the effect ends. 0 picks 4 s.
    #[arg(long = "hold-frames", default_value_t = 0, value_parser = parse_non_negative_int)]
    pub hold_frames: i64,

    /// Times the factory builds the text (each run starts again from the blueprint) before the effect ends.
    #[arg(long = "cycles", default_value_t = 1, value_parser = crate::effects::common::parse_positive_int)]
    pub cycles: i64,

    /// Space separated, unquoted, list of final colors, laid over the text in a diagonal pattern.
    #[arg(long = "final-colors", num_args = 1.., value_parser = parse_color,
          default_values = ["696960", "c1703e", "c1703e"])]
    pub final_colors: Vec<Color>,

    /// Space separated, unquoted, list of colors a placed character cools through (spark, yellow, orange).
    #[arg(long = "heat-colors", num_args = 1.., value_parser = parse_color,
          default_values = ["f8e8c2", "edc256", "dda13b"])]
    pub heat_colors: Vec<Color>,

    /// Color of the belt, trolleys and inserter arms.
    #[arg(long = "steel-color", default_value = "696960", value_parser = parse_color)]
    pub steel_color: Color,

    /// Color of the blueprint dots of unbuilt characters and of the rails.
    #[arg(long = "blueprint-color", default_value = "41433f", value_parser = parse_color)]
    pub blueprint_color: Color,

    /// Two colors for the items riding the belt.
    #[arg(long = "item-colors", num_args = 2, value_parser = parse_color,
          default_values = ["dda13b", "c1703e"])]
    pub item_colors: Vec<Color>,

    /// Two colors for the circuit lights: working, done.
    #[arg(long = "signal-colors", num_args = 2, value_parser = parse_color,
          default_values = ["c85e40", "a3a752"])]
    pub signal_colors: Vec<Color>,
}

/// One character's trip: off the belt, up the arm, onto its cell.
#[derive(Clone, Copy)]
struct Launch {
    slot: u32,
    column: i64,
    row: i64,
    /// Rows from the belt to the cell.
    dist: i64,
    launch: i64,
    land: i64,
}

/// One gantry: its schedule and its pieces (all added characters).
struct Gantry {
    launches: Vec<Launch>,
    /// The gantry's column on every frame of its build.
    track: Vec<i64>,
    /// The frame after its last landing.
    end: i64,
    /// The next launch to start.
    next: usize,
    /// Characters in flight: (launch index, item piece).
    flying: Vec<(usize, u32)>,
    free: Vec<u32>,
    /// The arm, from the belt toward the text.
    arm: Vec<u32>,
    trolley: [u32; 5],
    /// The grab on the belt.
    pickup: u32,
    /// The spark on the cell about to be filled.
    feed: u32,
}

/// Rows of the factory around the text.
#[derive(Clone, Copy)]
struct Layout {
    belt: Option<i64>,
    /// Row step from the text toward the belt (-1 belt below, 1 above).
    toward: i64,
    guide: Option<i64>,
}

/// Visuals of the decor, made once.
#[derive(Clone, Copy)]
struct Decor {
    belt_open: Visual,
    belt_close: Visual,
    belt_arrow: Visual,
    belt_plain: Visual,
    rail_plain: Visual,
    rail_post: Visual,
    rail_pulse: Visual,
    arm_steel: Visual,
    arm_grip: Visual,
    arm_reach: Visual,
    trolley_plus: Visual,
    trolley_ready: Visual,
    trolley_dash: Visual,
    feed_spark: Visual,
    feed_hot: Visual,
    pickup: Visual,
    pickup_hot: Visual,
    light_red: Visual,
    light_amber: Visual,
    light_green: Visual,
    light_green_bright: Visual,
    prog_filled: Visual,
    prog_empty: Visual,
    online_chars: [Visual; 6],
    meter_levels: [Visual; 4],
    meter_idle: Visual,
}

/// Width of each circuit pulse along connected letter strokes, in BFS steps.
const PULSE_WIDTH: i64 = 7;

/// Precomputed colors for circuit pulses (fg, optional subtle bg glow).
#[derive(Clone, Copy)]
struct PulsePalette {
    gold_core: (Color, Color),
    gold_mid: (Color, Color),
    gold_tail: Color,
    green_core: (Color, Color),
    green_mid: (Color, Color),
    green_tail: Color,
    sync_core: (Color, Color),
}

pub struct Factorio {
    config: FactorioConfig,
    /// Every input character, and which of them get built.
    chars: Vec<u32>,
    cells: Vec<u32>,
    built: usize,
    /// Frames of one build: build, cool, hold.
    cycle: i64,
    build_frames: i64,
    cool: i64,
    hold: i64,
    flourish_frames: i64,
    shutdown_frames: i64,
    total: i64,
    tick: i64,
    /// Frames per motion step (belt shift, blink): the frame rate / 60.
    step: i64,
    lift: i64,
    gantries: Vec<Gantry>,
    /// Placed characters still cooling: (slot, frame placed).
    cooling: VecDeque<(u32, i64)>,
    placed: usize,
    /// Per character slot: its final visual and its heat visuals (spark,
    /// yellow, orange), made on first use.
    finals: Vec<Option<[Visual; 4]>>,
    /// Belt pieces: (slot, column, moving).
    belt: Vec<(u32, i64, bool)>,
    /// Static decor that powers down with the belt: (slot, column).
    fixtures: Vec<(u32, i64)>,
    /// Circuit lights: (slot, column).
    lights: Vec<(u32, i64)>,
    /// Status readout on the light row (build progress bar -> ONLINE).
    status_slots: Vec<(u32, i64)>,
    /// Right-side circuit activity meter pips on the light row.
    meter_slots: Vec<(u32, i64)>,
    decor: Option<Decor>,
    palette: Option<PulsePalette>,
    layout: Layout,
    /// Text horizontal span (clamped to canvas) for rail pulse scaling.
    text_span: (i64, i64),
    /// Built cells ordered by stroke-following BFS circuit key.
    circuit: Vec<(i64, u32)>,
    /// Slots currently highlighted by an active circuit pulse.
    circuit_lit: Vec<u32>,
    landed: Vec<u32>,
    dot: Sym,
}

impl Factorio {
    pub fn new(config: FactorioConfig) -> Self {
        Factorio {
            config,
            chars: Vec::new(),
            cells: Vec::new(),
            built: 0,
            cycle: 1,
            build_frames: 0,
            cool: 0,
            hold: 0,
            flourish_frames: 0,
            shutdown_frames: 0,
            total: 0,
            tick: 0,
            step: 1,
            lift: 1,
            gantries: Vec::new(),
            cooling: VecDeque::new(),
            placed: 0,
            finals: Vec::new(),
            belt: Vec::new(),
            fixtures: Vec::new(),
            lights: Vec::new(),
            status_slots: Vec::new(),
            meter_slots: Vec::new(),
            decor: None,
            palette: None,
            layout: Layout {
                belt: None,
                toward: -1,
                guide: None,
            },
            text_span: (1, 1),
            circuit: Vec::new(),
            circuit_lit: Vec::new(),
            landed: Vec::new(),
            dot: Sym(0),
        }
    }

    /// The visual of an input character in `fg`; under
    /// --existing-color-handling always, its input colors instead.
    fn char_visual(e: &mut Engine, slot: u32, sym: Sym, fg: Color) -> Visual {
        let info = if e.existing_color_handling() == ExistingColorHandling::Always
            && e.uses_preexisting_colors(slot)
        {
            input_info(e, slot, sym)
        } else {
            // whitespace (built only when colored) glows as a background
            let blank = e.symbol(sym).trim().is_empty();
            VisualInfo {
                sym,
                fg: (!blank).then_some(fg),
                bg: blank.then_some(fg),
                attrs: HAS_COLORS,
            }
        };
        e.visuals.make(&e.symbols, info)
    }

    /// The character's final visual: under dynamic or always handling with
    /// colored input, its input colors (none for an uncolored character, as
    /// the engine marks every character of colored input); else the final
    /// color pattern.
    fn final_visual(&self, e: &mut Engine, slot: u32) -> Visual {
        let sym = e.input_sym(slot);
        let handling = e.existing_color_handling();
        if handling != ExistingColorHandling::Ignore && e.uses_preexisting_colors(slot) {
            let info = input_info(e, slot, sym);
            return e.visuals.make(&e.symbols, info);
        }
        let c = e.input_coord(slot);
        let colors = &self.config.final_colors;
        let i = (c.column + c.row).rem_euclid(colors.len() as i64) as usize;
        Self::char_visual(e, slot, sym, colors[i])
    }

    fn heat_color(&self, stage: usize) -> Color {
        let heat = &self.config.heat_colors;
        heat[stage.min(heat.len() - 1)]
    }

    /// The visuals of a character: final, spark, yellow, orange.
    fn visuals_of(&mut self, e: &mut Engine, slot: u32) -> [Visual; 4] {
        if let Some(Some(v)) = self.finals.get(slot as usize) {
            return *v;
        }
        let sym = e.input_sym(slot);
        let v = [
            self.final_visual(e, slot),
            Self::char_visual(e, slot, sym, self.heat_color(0)),
            Self::char_visual(e, slot, sym, self.heat_color(1)),
            Self::char_visual(e, slot, sym, self.heat_color(2)),
        ];
        if self.finals.len() <= slot as usize {
            self.finals.resize(slot as usize + 1, None);
        }
        self.finals[slot as usize] = Some(v);
        v
    }

    /// The heat stage visual index for a character placed `age` frames ago.
    fn stage(&self, age: i64) -> usize {
        let c = self.cool;
        if age >= c {
            0
        } else if age < (c + 5) / 6 {
            1
        } else if age < (c + 1) / 2 {
            2
        } else {
            3
        }
    }

    /// The visual of an input character in `fg` with an optional subtle `bg` glow;
    /// under --existing-color-handling always, its input colors instead.
    fn char_visual_bg(
        e: &mut Engine,
        slot: u32,
        sym: Sym,
        fg: Color,
        bg: Option<Color>,
    ) -> Visual {
        let info = if e.existing_color_handling() == ExistingColorHandling::Always
            && e.uses_preexisting_colors(slot)
        {
            input_info(e, slot, sym)
        } else {
            // whitespace (built only when colored) glows as a background
            let blank = e.symbol(sym).trim().is_empty();
            VisualInfo {
                sym,
                fg: (!blank).then_some(fg),
                bg: if blank { Some(fg) } else { bg },
                attrs: HAS_COLORS,
            }
        };
        e.visuals.make(&e.symbols, info)
    }

    fn visual(e: &mut Engine, symbol: &str, fg: Color) -> Visual {
        Self::visual_bg(e, symbol, fg, None)
    }

    fn visual_bg(e: &mut Engine, symbol: &str, fg: Color, bg: Option<Color>) -> Visual {
        let sym = e.sym(symbol);
        e.visuals.make(
            &e.symbols,
            VisualInfo {
                sym,
                fg: Some(fg),
                bg,
                attrs: HAS_COLORS,
            },
        )
    }

    /// An added decor character, hidden, on layer `layer`.
    fn piece(e: &mut Engine, symbol: &str, coord: Coord, layer: i32) -> u32 {
        let slot = e.add_character(symbol, coord);
        e.set_layer(slot, layer);
        slot
    }

    /// Place `slot` and show `visual` there, or hide it when off the canvas.
    fn show_at(e: &mut Engine, slot: u32, coord: Coord, visual: Visual) {
        if e.canvas.coord_is_in_canvas(coord) {
            e.set_coordinate(slot, coord);
            e.set_visual(slot, visual);
            e.set_visible(slot, true);
        } else {
            e.set_visible(slot, false);
        }
    }

    /// Start, fly and land gantry `i`'s characters at frame `t`, then draw it.
    fn run_gantry(&mut self, e: &mut Engine, i: usize, t: i64, wipe: i64) {
        let Some(d) = self.decor else {
            return;
        };
        let lay = self.layout;
        let (step, lift) = (self.step, self.lift);
        let g = &mut self.gantries[i];
        while g.next < g.launches.len() && g.launches[g.next].launch <= t {
            let piece = g.free.pop().expect("item pool sized by the schedule");
            g.flying.push((g.next, piece));
            g.next += 1;
        }
        let mut k = 0;
        while k < g.flying.len() {
            let (at, piece) = g.flying[k];
            if g.launches[at].land <= t {
                self.landed.push(g.launches[at].slot);
                e.set_visible(piece, false);
                g.free.push(piece);
                g.flying.swap_remove(k);
            } else {
                k += 1;
            }
        }

        // the trolley on the guide rail, parked once the gantry is done
        let working = t < g.end;
        let column = g.track[(t.max(0) as usize).min(g.track.len() - 1)];
        for (k, &slot) in g.trolley.iter().enumerate() {
            let offset = k as i64 - 2;
            match lay.guide {
                Some(row) if column + offset >= wipe => {
                    let v = if !working && offset == 0 {
                        d.trolley_ready
                    } else if offset % 2 != 0 {
                        d.trolley_plus
                    } else {
                        d.trolley_dash
                    };
                    Self::show_at(e, slot, Coord::new(column + offset, row), v);
                }
                _ => e.set_visible(slot, false),
            }
        }
        let (Some(belt), true) = (lay.belt, working) else {
            for &slot in g.arm.iter().chain([&g.pickup, &g.feed]) {
                e.set_visible(slot, false);
            }
            return;
        };
        let blink = (t / (2 * step)) % 2 == 0;

        // the arm reaches the farthest character in flight in its column
        let reach = g
            .flying
            .iter()
            .map(|&(at, _)| g.launches[at])
            .filter(|l| l.column == column)
            .map(|l| l.dist)
            .max()
            .unwrap_or(0);
        for (k, &slot) in g.arm.iter().enumerate() {
            let k = k as i64 + 1;
            if k >= reach {
                e.set_visible(slot, false);
                continue;
            }
            let v = if k + 1 == reach {
                if blink {
                    d.arm_grip
                } else {
                    d.arm_reach
                }
            } else {
                d.arm_steel
            };
            Self::show_at(e, slot, Coord::new(column, belt - lay.toward * k), v);
        }
        let grabbing = g.flying.iter().any(|&(at, _)| g.launches[at].launch + step > t);
        let v = if grabbing { d.pickup_hot } else { d.pickup };
        Self::show_at(e, g.pickup, Coord::new(column, belt), v);

        // the characters rising, and the spark where the next one lands
        let flying = std::mem::take(&mut g.flying);
        let mut next: Option<Launch> = None;
        for &(at, piece) in &flying {
            let l = self.gantries[i].launches[at];
            let k = ((t - l.launch) / lift.max(1)).min(l.dist);
            let v = self.visuals_of(e, l.slot)[if (k / 2) % 3 == 2 { 2 } else { 1 }];
            Self::show_at(e, piece, Coord::new(l.column, belt - lay.toward * k), v);
            if next.is_none_or(|n| l.land < n.land) {
                next = Some(l);
            }
        }
        let g = &mut self.gantries[i];
        g.flying = flying;
        match next {
            Some(l) => {
                let v = if blink { d.feed_spark } else { d.feed_hot };
                Self::show_at(e, g.feed, Coord::new(l.column, l.row), v);
            }
            None => e.set_visible(g.feed, false),
        }
    }

    /// Every cell to build shows a dim dot; the gantries start over.
    fn blueprint(&mut self, e: &mut Engine) {
        let blueprint = self.config.blueprint_color;
        for &s in &self.cells {
            let v = Self::char_visual(e, s, self.dot, blueprint);
            e.set_visual(s, v);
            e.set_layer(s, 0);
            e.set_visible(s, true);
        }
        self.placed = 0;
        self.cooling.clear();
        self.circuit_lit.clear();
        for g in &mut self.gantries {
            for (_, piece) in g.flying.drain(..) {
                e.set_visible(piece, false);
                g.free.push(piece);
            }
            g.next = 0;
        }
    }

    /// Electric current pulses race along the connected strokes of the finished
    /// letters like Factorio circuit traces; `at` is the frame within the
    /// flourish, None to restore all lit cells cleanly.
    fn update_circuit(&mut self, e: &mut Engine, at: Option<i64>) {
        let lit = std::mem::take(&mut self.circuit_lit);
        for slot in lit {
            let v = self.visuals_of(e, slot)[0];
            e.set_visual(slot, v);
        }
        let (Some(at), Some(pal), Some(&(first, _)), Some(&(last, _))) = (
            at,
            self.palette,
            self.circuit.first(),
            self.circuit.last(),
        ) else {
            return;
        };
        if self.flourish_frames <= 0 {
            return;
        }
        let u = at as f64 / self.flourish_frames as f64;
        let span = (last - first + PULSE_WIDTH).max(1) as f64;

        // Three overlapping current pulses:
        // 0: Golden power-grid energize (forward along strokes)
        // 1: Electric circuit-green telemetry (reverse along strokes)
        // 2: Bright green-to-copper final sync surge (forward along strokes)
        let waves: [(f64, f64, bool, u8); 3] = [
            (0.00, 0.52, true, 0),
            (0.28, 0.80, false, 1),
            (0.58, 1.00, true, 2),
        ];
        for (start, end, forward, kind) in waves {
            if u < start || u >= end {
                continue;
            }
            let p = (u - start) / (end - start);
            let (lo_key, hi_key, head) = if forward {
                let h = first + (span * p).floor() as i64;
                (h - PULSE_WIDTH + 1, h, h)
            } else {
                let h = last - (span * p).floor() as i64;
                (h, h + PULSE_WIDTH - 1, h)
            };
            let lo = self.circuit.partition_point(|&(key, _)| key < lo_key);
            let hi = self.circuit.partition_point(|&(key, _)| key <= hi_key);
            for k in lo..hi {
                let (key, slot) = self.circuit[k];
                let dist = if forward { head - key } else { key - head };
                let (fg, bg) = match (kind, dist) {
                    (0, 0..=1) => (pal.gold_core.0, Some(pal.gold_core.1)),
                    (0, 2..=4) => (pal.gold_mid.0, Some(pal.gold_mid.1)),
                    (0, _) => (pal.gold_tail, None),
                    (1, 0..=1) => (pal.green_core.0, Some(pal.green_core.1)),
                    (1, 2..=4) => (pal.green_mid.0, Some(pal.green_mid.1)),
                    (1, _) => (pal.green_tail, None),
                    (_, 0..=1) => (pal.sync_core.0, Some(pal.sync_core.1)),
                    (_, 2..=4) => (pal.green_mid.0, Some(pal.green_mid.1)),
                    _ => (pal.gold_tail, None),
                };
                let sym = e.input_sym(slot);
                let v = Self::char_visual_bg(e, slot, sym, fg, bg);
                e.set_visual(slot, v);
                self.circuit_lit.push(slot);
            }
        }
    }

    fn finish(&mut self, e: &mut Engine) {
        self.circuit_lit.clear();
        for g in &self.gantries {
            for &slot in g
                .arm
                .iter()
                .chain(&g.trolley)
                .chain(&g.free)
                .chain([&g.pickup, &g.feed])
            {
                e.set_visible(slot, false);
            }
            for &(_, slot) in &g.flying {
                e.set_visible(slot, false);
            }
        }
        for &(slot, _, _) in &self.belt {
            e.set_visible(slot, false);
        }
        for &(slot, _) in self
            .fixtures
            .iter()
            .chain(&self.lights)
            .chain(&self.status_slots)
            .chain(&self.meter_slots)
        {
            e.set_visible(slot, false);
        }
        for k in 0..self.chars.len() {
            let slot = self.chars[k];
            let v = self.visuals_of(e, slot)[0];
            e.set_visual(slot, v);
            e.set_layer(slot, 2);
            e.set_visible(slot, true);
        }
    }
}

fn rgb_color(r: u8, g: u8, b: u8) -> Color {
    Color::from_hex(&format!("{r:02x}{g:02x}{b:02x}")).expect("valid hex")
}

fn blend_color(a: Color, b: Color, t: f64) -> Color {
    let (ar, ag, ab) = a.rgb_ints();
    let (br, bg, bb) = b.rgb_ints();
    let mix = |x: u8, y: u8| -> u8 {
        ((x as f64) * (1.0 - t) + (y as f64) * t)
            .round()
            .clamp(0.0, 255.0) as u8
    };
    rgb_color(mix(ar, br), mix(ag, bg), mix(ab, bb))
}

fn dim_color(c: Color, factor: f64) -> Color {
    let (r, g, b) = c.rgb_ints();
    let scale = |x: u8| -> u8 { ((x as f64) * factor).round().clamp(0.0, 255.0) as u8 };
    rgb_color(scale(r), scale(g), scale(b))
}

/// Group built cells into 8-connected components ordered left-to-right, and
/// assign each cell a circuit-trace key by BFS distance from the cell of its
/// component closest to the conveyor belt. Pulses along this key flow cleanly
/// up letter stems, split across crossbars, and cascade from letter to letter.
fn build_circuit(cells: &[u32], e: &Engine, toward: i64) -> Vec<(i64, u32)> {
    if cells.is_empty() {
        return Vec::new();
    }
    let index: HashMap<(i64, i64), usize> = cells
        .iter()
        .enumerate()
        .map(|(i, &s)| {
            let c = e.input_coord(s);
            ((c.column, c.row), i)
        })
        .collect();
    const STEPS: [(i64, i64); 8] = [
        (-1, 1),
        (0, 1),
        (1, 1),
        (-1, 0),
        (1, 0),
        (-1, -1),
        (0, -1),
        (1, -1),
    ];
    let mut seen = vec![false; cells.len()];
    let mut comps: Vec<(i64, i64, Vec<usize>)> = Vec::new();
    let mut stack = Vec::new();
    for start in 0..cells.len() {
        if seen[start] {
            continue;
        }
        seen[start] = true;
        stack.push(start);
        let mut comp = Vec::new();
        let mut min_col = i64::MAX;
        let mut max_row = i64::MIN;
        while let Some(u) = stack.pop() {
            comp.push(u);
            let c = e.input_coord(cells[u]);
            min_col = min_col.min(c.column);
            max_row = max_row.max(c.row);
            for (dx, dy) in STEPS {
                if let Some(&v) = index.get(&(c.column + dx, c.row + dy)) {
                    if !seen[v] {
                        seen[v] = true;
                        stack.push(v);
                    }
                }
            }
        }
        comps.push((min_col, -max_row, comp));
    }
    comps.sort_by_key(|&(col, neg_row, _)| (col, neg_row));

    let stagger: i64 = if comps.len() <= 12 {
        5
    } else if comps.len() <= 30 {
        2
    } else {
        1
    };

    let mut dist = vec![i64::MAX; cells.len()];
    let mut queue = VecDeque::new();
    let mut out = Vec::with_capacity(cells.len());
    for (ci, (_, _, comp)) in comps.iter().enumerate() {
        // Entry cell: closest to the belt, leftmost as tie-breaker.
        let entry = *comp
            .iter()
            .min_by_key(|&&idx| {
                let c = e.input_coord(cells[idx]);
                (-toward * c.row, c.column)
            })
            .expect("non-empty component");
        dist[entry] = 0;
        queue.push_back(entry);
        let offset = (ci as i64) * stagger;
        while let Some(u) = queue.pop_front() {
            let du = dist[u];
            out.push((offset + du, cells[u]));
            let c = e.input_coord(cells[u]);
            for (dx, dy) in STEPS {
                if let Some(&v) = index.get(&(c.column + dx, c.row + dy)) {
                    if dist[v] == i64::MAX {
                        dist[v] = du + 1;
                        queue.push_back(v);
                    }
                }
            }
        }
    }
    out.sort_by_key(|&(key, _)| key);
    out
}

fn input_info(e: &Engine, slot: u32, sym: Sym) -> VisualInfo {
    let bold = e.existing_color_handling() == ExistingColorHandling::Always && e.input_bold(slot);
    VisualInfo {
        sym,
        fg: e.input_fg(slot),
        bg: e.input_bg(slot),
        attrs: HAS_COLORS | if bold { BOLD } else { 0 },
    }
}

/// Screen order key: top row first, then left to right.
fn reading_key(c: Coord) -> (i64, i64) {
    (-c.row, c.column)
}

/// Depth-first walk along 8-connected strokes (the original's trace_order,
/// without the backtracking revisits), components top-left first.
fn trace(cells: &[u32], e: &Engine) -> Vec<u32> {
    let mut sorted: Vec<u32> = cells.to_vec();
    sorted.sort_by_key(|&s| reading_key(e.input_coord(s)));
    let index: HashMap<(i64, i64), usize> = sorted
        .iter()
        .enumerate()
        .map(|(i, &s)| {
            let c = e.input_coord(s);
            ((c.column, c.row), i)
        })
        .collect();
    // screen order: the row above first (row + 1), left to right
    const STEPS: [(i64, i64); 8] = [
        (-1, 1),
        (0, 1),
        (1, 1),
        (-1, 0),
        (1, 0),
        (-1, -1),
        (0, -1),
        (1, -1),
    ];
    let mut visited = vec![false; sorted.len()];
    let mut order = Vec::with_capacity(sorted.len());
    let mut stack: Vec<(usize, usize)> = Vec::new();
    for start in 0..sorted.len() {
        if visited[start] {
            continue;
        }
        visited[start] = true;
        order.push(sorted[start]);
        stack.push((start, 0));
        while let Some(top) = stack.last_mut() {
            let (at, k) = *top;
            if k >= STEPS.len() {
                stack.pop();
                continue;
            }
            top.1 += 1;
            let c = e.input_coord(sorted[at]);
            let (dx, dy) = STEPS[k];
            if let Some(&next) = index.get(&(c.column + dx, c.row + dy)) {
                if !visited[next] {
                    visited[next] = true;
                    order.push(sorted[next]);
                    stack.push((next, 0));
                }
            }
        }
    }
    order
}

/// Split the cells (sorted by column) into at most `count` bands of whole
/// columns. The glyphs (runs of columns between blank ones) are the units;
/// a glyph much larger than an even share is cut into column pieces first.
/// The units are then grouped into contiguous bands with the smallest
/// largest band (linear partition).
fn bands(cells: &[u32], e: &Engine, count: usize) -> Vec<Vec<u32>> {
    let n = cells.len();
    if count <= 1 || n == 0 {
        return vec![cells.to_vec()];
    }
    let left = e.input_coord(cells[0]).column;
    let right = e.input_coord(cells[n - 1]).column;
    let width = (right - left + 1) as usize;
    let mut per_column = vec![0usize; width];
    for &s in cells {
        per_column[(e.input_coord(s).column - left) as usize] += 1;
    }
    // glyphs: (first column, last column, cells)
    let mut glyphs: Vec<(usize, usize, usize)> = Vec::new();
    for (c, &k) in per_column.iter().enumerate() {
        match glyphs.last_mut() {
            Some(g) if k > 0 && g.1 + 1 == c => {
                g.1 = c;
                g.2 += k;
            }
            _ if k > 0 => glyphs.push((c, c, k)),
            _ => {}
        }
    }
    // units: glyphs, the large ones cut into pieces of about a share
    let share = n as f64 / count as f64;
    let mut units: Vec<(usize, usize)> = Vec::new(); // (last column, cells)
    for &(first, last, size) in &glyphs {
        let pieces = if size as f64 > 1.5 * share {
            (size as f64 / share).round().max(1.0) as usize
        } else {
            1
        };
        let (mut sum, mut acc) = (0, 0);
        let mut piece = 1;
        for (c, &k) in per_column.iter().enumerate().take(last + 1).skip(first) {
            sum += k;
            acc += k;
            if (acc >= size * piece / pieces && piece < pieces) || c == last {
                units.push((c, sum));
                sum = 0;
                piece += 1;
            }
        }
    }
    let u = units.len();
    let count = count.min(u);
    // best[b][i]: the smallest largest band covering units[..i] in b bands
    let mut prefix = vec![0usize; u + 1];
    for i in 0..u {
        prefix[i + 1] = prefix[i] + units[i].1;
    }
    let mut best = vec![vec![usize::MAX; u + 1]; count + 1];
    let mut cut = vec![vec![0usize; u + 1]; count + 1];
    best[0][0] = 0;
    for b in 1..=count {
        for i in b..=u {
            for j in (b - 1)..i {
                if best[b - 1][j] == usize::MAX {
                    continue;
                }
                let cost = best[b - 1][j].max(prefix[i] - prefix[j]);
                if cost < best[b][i] {
                    best[b][i] = cost;
                    cut[b][i] = j;
                }
            }
        }
    }
    // the last column of each band, right to left
    let mut ends = Vec::with_capacity(count);
    let mut i = u;
    for b in (1..=count).rev() {
        ends.push(units[i - 1].0);
        i = cut[b][i];
    }
    ends.reverse();
    let mut out: Vec<Vec<u32>> = vec![Vec::new(); ends.len()];
    for &s in cells {
        let c = (e.input_coord(s).column - left) as usize;
        out[ends.partition_point(|&end| end < c)].push(s);
    }
    out.retain(|b| !b.is_empty());
    out
}

/// Push the gantry's column until the track covers frame `t`.
fn fill(track: &mut Vec<i64>, t: i64, column: i64) {
    while (track.len() as i64) < t {
        track.push(column);
    }
}

/// Schedule one gantry: each character leaves the belt `delay` frames after
/// the one before, rises `lift` frames per row and lands on its cell; the
/// gantry moves `travel` frames per column to the next character's column.
/// A character bound farther up its column than the one before waits for it
/// to land, so the two never pass.
fn schedule(
    route: &[u32],
    e: &Engine,
    belt: Option<i64>,
    delay: i64,
    lift: i64,
    travel: i64,
) -> (Vec<Launch>, Vec<i64>, i64) {
    let mut launches = Vec::with_capacity(route.len());
    let mut track = Vec::new();
    let Some(&first) = route.first() else {
        return (launches, vec![1], 0);
    };
    let mut column = e.input_coord(first).column;
    let mut t = 0;
    let mut end = 0;
    let mut previous: Option<Launch> = None;
    for &slot in route {
        let c = e.input_coord(slot);
        let dist = belt.map_or(0, |b| (c.row - b).abs());
        if c.column != column {
            let step = (c.column - column).signum();
            while c.column != column {
                fill(&mut track, t, column);
                t += travel;
                column += step;
            }
        } else if let Some(p) = previous.filter(|p| p.column == column && dist > p.dist) {
            t = t.max(p.land);
        }
        fill(&mut track, t, column);
        let l = Launch {
            slot,
            column,
            row: c.row,
            dist,
            launch: t,
            land: t + dist * lift,
        };
        end = end.max(l.land + 1);
        launches.push(l);
        previous = Some(l);
        t += delay;
    }
    fill(&mut track, end.max(1), column);
    (launches, track, end)
}

/// Speed a schedule up by `to / from` (to < from): every launch, landing
/// and gantry position comes earlier in proportion.
fn compress(schedule: &mut (Vec<Launch>, Vec<i64>, i64), from: i64, to: i64) {
    let (launches, track, end) = schedule;
    let at = |t: i64| t * to / from;
    for l in launches.iter_mut() {
        l.launch = at(l.launch);
        l.land = at(l.land).max(l.launch);
    }
    *end = launches.iter().map(|l| l.land + 1).max().unwrap_or(0);
    let old = std::mem::take(track);
    *track = (0..(*end).max(1))
        .map(|t| old[((t * from / to) as usize).min(old.len() - 1)])
        .collect();
}

/// The most characters of one schedule held at once (in flight, or
/// launched and landing on the same frame).
fn in_flight(launches: &[Launch]) -> usize {
    let mut lands = BinaryHeap::new();
    let mut most = 0;
    for l in launches {
        // a frame starts its launches before it lands the arrivals
        while lands.peek().is_some_and(|&Reverse(land)| land < l.launch) {
            lands.pop();
        }
        lands.push(Reverse(l.land));
        most = most.max(lands.len());
    }
    most
}

impl Hooks for Factorio {}

impl Effect for Factorio {
    fn build(&mut self, e: &mut Engine) -> Result<(), EngineError> {
        let config = self.config.clone();
        self.dot = e.sym(".");
        self.chars = e.input_chars.clone();
        let space = e.sym(" ");
        let handling = e.existing_color_handling();
        // the cells to build: visible characters on the canvas
        let mut cells: Vec<u32> = self
            .chars
            .iter()
            .copied()
            .filter(|&s| {
                let sym = e.input_sym(s);
                // whitespace is built only when it shows input colors
                let colored = handling != ExistingColorHandling::Ignore
                    && (e.input_fg(s).is_some() || e.input_bg(s).is_some());
                (colored || (sym != space && !e.symbol(sym).chars().all(char::is_whitespace)))
                    && e.canvas.coord_is_in_canvas(e.input_coord(s))
            })
            .collect();
        self.built = cells.len();
        if cells.is_empty() {
            self.total = 0;
            return Ok(());
        }

        // timing follows the frame rate
        let fps = if e.config.frame_rate > 0 {
            e.config.frame_rate
        } else {
            60
        };
        let auto = |value: i64, default: i64| if value > 0 { value } else { default.max(1) };
        self.step = ((fps as f64 / 60.0).round() as i64).max(1);
        self.lift = auto(config.lift_frames, self.step);
        self.cool = auto(config.cool_frames, fps / 5);
        self.hold = auto(config.hold_frames, 4 * fps);

        // layout around the text's bounding box
        let (mut left, mut right, mut bottom, mut top) = (i64::MAX, i64::MIN, i64::MAX, i64::MIN);
        for &s in &cells {
            let c = e.input_coord(s);
            left = left.min(c.column);
            right = right.max(c.column);
            bottom = bottom.min(c.row);
            top = top.max(c.row);
        }
        let (canvas_bottom, canvas_top) = (1, e.canvas.top);
        let fits = |row: i64| (canvas_bottom..=canvas_top).contains(&row);
        let (belt_row, rail_row, guide_row, light_row, toward) = if fits(bottom - 2) {
            (bottom - 2, bottom - 3, top + 1, top + 2, -1)
        } else if fits(top + 2) {
            (top + 2, top + 3, bottom - 1, bottom - 2, 1)
        } else {
            (canvas_bottom, canvas_bottom - 1, top + 1, top + 2, -1)
        };
        self.layout = Layout {
            belt: fits(belt_row).then_some(belt_row),
            toward,
            guide: fits(guide_row).then_some(guide_row),
        };

        // gantries: column bands, split between glyphs
        let n = cells.len();
        cells.sort_by_key(|&s| {
            let c = e.input_coord(s);
            (c.column, -c.row)
        });
        let width = right - left + 1;
        let count = if config.inserters > 0 {
            config.inserters as usize
        } else {
            n.div_ceil(70).min((width / 8).max(1) as usize)
        }
        .clamp(1, n);
        let mut routes = bands(&cells, e, count);
        for route in &mut routes {
            match config.build_order {
                // far end of the column first: characters never pass each other
                BuildOrder::Columns => route.sort_by_key(|&s| {
                    let c = e.input_coord(s);
                    (c.column, c.row * toward)
                }),
                BuildOrder::Reading => route.sort_by_key(|&s| reading_key(e.input_coord(s))),
                BuildOrder::Trace => *route = trace(route, e),
                BuildOrder::Random => {
                    route.sort_by_key(|&s| reading_key(e.input_coord(s)));
                    e.rng.shuffle(route);
                }
            }
        }
        let most = routes.iter().map(Vec::len).max().unwrap_or(1).max(1) as i64;
        // about 15 characters a second on the busiest gantry, faster when
        // its band is so large the build would run past ~9 s; the others
        // work up to half as fast so the letters finish closer together
        let base = (4 * self.step).min(9 * fps / most).max(1);
        let belt = self.layout.belt;
        let mut schedules: Vec<_> = routes
            .iter()
            .map(|r| {
                let delay = auto(
                    config.place_delay,
                    (base * most / r.len().max(1) as i64).min(2 * base),
                );
                schedule(r, e, belt, delay, self.lift, self.step)
            })
            .collect();
        // with automatic timing, gantry moves (reading, trace and random
        // orders on large texts) may not stretch the build past ~12 s: the
        // schedules are sped up to fit
        let longest = schedules.iter().map(|s| s.2).max().unwrap_or(0);
        let budget = 12 * fps;
        if config.place_delay == 0 && config.lift_frames == 0 && longest > budget {
            for s in &mut schedules {
                compress(s, longest, budget);
            }
        }
        self.build_frames = schedules.iter().map(|s| s.2).max().unwrap_or(0).max(1);
        self.flourish_frames = self.hold * 4 / 5;
        self.shutdown_frames = self.hold - self.flourish_frames;
        self.cycle = self.build_frames + self.cool + self.hold;
        self.total = self.cycle * config.cycles;

        // decor visuals & circuit-pulse palette
        let steel = config.steel_color;
        let blueprint = config.blueprint_color;
        let [spark, yellow, orange] = [0, 1, 2].map(|i| self.heat_color(i));
        let (item_a, item_b) = (config.item_colors[0], config.item_colors[1]);
        let (red, green) = (config.signal_colors[0], config.signal_colors[1]);
        let green_vivid = blend_color(green, rgb_color(94, 240, 112), 0.55);
        let green_bright = blend_color(green_vivid, rgb_color(232, 255, 206), 0.50);
        let green_glow = dim_color(green_vivid, 0.22);
        let green_glow_soft = dim_color(green_vivid, 0.13);
        let gold_glow = dim_color(yellow, 0.20);
        let gold_glow_soft = dim_color(orange, 0.13);
        let red_glow = dim_color(red, 0.22);
        let grip = if toward < 0 { "^" } else { "v" };
        self.palette = Some(PulsePalette {
            gold_core: (spark, gold_glow),
            gold_mid: (yellow, gold_glow_soft),
            gold_tail: orange,
            green_core: (green_bright, green_glow),
            green_mid: (green_vivid, green_glow_soft),
            green_tail: green,
            sync_core: (blend_color(spark, green_bright, 0.5), green_glow),
        });
        let online_text = ["O", "N", "L", "I", "N", "E"];
        let online_chars = online_text.map(|ch| Self::visual(e, ch, green_bright));
        let meter_syms = ["▁", "▂", "▄", "▆"];
        let meter_levels = meter_syms.map(|ch| Self::visual(e, ch, green_vivid));
        self.decor = Some(Decor {
            belt_open: Self::visual(e, "[", item_a),
            belt_close: Self::visual(e, "]", item_b),
            belt_arrow: Self::visual(e, ">", steel),
            belt_plain: Self::visual(e, "=", steel),
            rail_plain: Self::visual(e, "=", blueprint),
            rail_post: Self::visual(e, "|", blueprint),
            rail_pulse: Self::visual(e, "═", green_vivid),
            arm_steel: Self::visual(e, "|", steel),
            arm_grip: Self::visual(e, grip, yellow),
            arm_reach: Self::visual(e, "|", orange),
            trolley_plus: Self::visual(e, "+", orange),
            trolley_ready: Self::visual(e, "+", green_vivid),
            trolley_dash: Self::visual(e, "-", steel),
            feed_spark: Self::visual(e, "*", spark),
            feed_hot: Self::visual(e, "*", yellow),
            pickup: Self::visual(e, "O", orange),
            pickup_hot: Self::visual(e, "O", spark),
            light_red: Self::visual_bg(e, "█", red, Some(red_glow)),
            light_amber: Self::visual(e, "▄", orange),
            light_green: Self::visual_bg(e, "█", green_vivid, Some(green_glow_soft)),
            light_green_bright: Self::visual_bg(e, "█", green_bright, Some(green_glow)),
            prog_filled: Self::visual(e, "▄", orange),
            prog_empty: Self::visual(e, "▁", blueprint),
            online_chars,
            meter_levels,
            meter_idle: Self::visual(e, "▁", blueprint),
        });

        // stroke-following circuit trace for the finished-logo current pulses
        self.circuit = build_circuit(&cells, e, toward);
        self.cells = cells;
        self.blueprint(e);

        // the belt runs the width of the canvas, its rail under it; the
        // guide rail spans the text
        if let Some(row) = self.layout.belt {
            for column in 1..=e.canvas.right {
                let slot = Self::piece(e, "=", Coord::new(column, row), 1);
                self.belt.push((slot, column, true));
            }
            if fits(rail_row) {
                for column in 1..=e.canvas.right {
                    let symbol = if column % 6 == 0 { "|" } else { "=" };
                    let slot = Self::piece(e, symbol, Coord::new(column, rail_row), 1);
                    let v = Self::visual(e, symbol, blueprint);
                    e.set_visual(slot, v);
                    self.belt.push((slot, column, false));
                }
            }
        }
        if let Some(row) = self.layout.guide {
            let v = Self::visual(e, "-", blueprint);
            for column in (left - 2).max(1)..=(right + 2).min(e.canvas.right) {
                let slot = Self::piece(e, "-", Coord::new(column, row), 1);
                e.set_visual(slot, v);
                self.fixtures.push((slot, column));
            }
        }
        let (left, right) = (left.max(1), right.min(e.canvas.right));
        self.text_span = (left, right);
        if fits(light_row) {
            for column in [left, right] {
                let slot = Self::piece(e, "█", Coord::new(column, light_row), 1);
                self.lights.push((slot, column));
                if left == right {
                    break;
                }
            }
            if right - left >= 16 {
                for k in 0..6i64 {
                    let col = left + 2 + k;
                    let slot = Self::piece(e, "▁", Coord::new(col, light_row), 1);
                    self.status_slots.push((slot, col));
                }
            }
            if right - left >= 20 {
                for k in 0..4i64 {
                    let col = right - 5 + k;
                    let slot = Self::piece(e, "▁", Coord::new(col, light_row), 1);
                    self.meter_slots.push((slot, col));
                }
            }
        }

        // the gantries' pieces
        for (launches, track, end) in schedules {
            let origin = Coord::new(left, top);
            let reach = launches.iter().map(|l| l.dist).max().unwrap_or(0) as usize;
            let arm = (0..reach).map(|_| Self::piece(e, "|", origin, 1)).collect();
            let free = (0..in_flight(&launches))
                .map(|_| Self::piece(e, "*", origin, 3))
                .collect();
            let trolley = [0; 5].map(|_| Self::piece(e, "-", origin, 2));
            let pickup = Self::piece(e, "O", origin, 2);
            let feed = Self::piece(e, "*", origin, 3);
            self.gantries.push(Gantry {
                launches,
                track,
                end,
                next: 0,
                flying: Vec::new(),
                free,
                arm,
                trolley,
                pickup,
                feed,
            });
        }
        Ok(())
    }

    fn next_frame(&mut self, e: &mut Engine) -> bool {
        if self.tick > self.total {
            return false;
        }
        if self.tick == self.total {
            self.finish(e);
            self.tick += 1;
            return true;
        }
        // the frame within this build; a new build starts from the blueprint
        let t = self.tick % self.cycle;
        let last = self.tick / self.cycle == self.config.cycles - 1;
        if t == 0 && self.tick > 0 {
            self.blueprint(e);
        }
        // power down: the belt stops and the line clears left to right
        let down = self.cycle - self.shutdown_frames;
        let wipe = if last && self.shutdown_frames > 0 && t >= down {
            1 + (e.canvas.right + 6) * (t - down + 1) / self.shutdown_frames
        } else {
            i64::MIN
        };

        // the gantries: launches, landings, arms
        for i in 0..self.gantries.len() {
            self.run_gantry(e, i, t, wipe);
        }
        let mut landed = std::mem::take(&mut self.landed);
        for &slot in &landed {
            let v = self.visuals_of(e, slot);
            e.set_visual(slot, v[self.stage(0)]);
            e.set_layer(slot, 2);
            self.cooling.push_back((slot, t));
            self.placed += 1;
        }
        landed.clear();
        self.landed = landed;

        // cooling
        for k in 0..self.cooling.len() {
            let (slot, at) = self.cooling[k];
            let stage = self.stage(t - at);
            let v = self.visuals_of(e, slot)[stage];
            e.set_visual(slot, v);
        }
        while self
            .cooling
            .front()
            .is_some_and(|&(_, at)| t - at >= self.cool)
        {
            self.cooling.pop_front();
        }

        // electric current pulses along the finished letter strokes
        let flourish_at = t - self.build_frames - self.cool;
        let in_flourish = (0..self.flourish_frames).contains(&flourish_at);
        if in_flourish {
            self.update_circuit(e, Some(flourish_at));
        } else if !self.circuit_lit.is_empty() {
            self.update_circuit(e, None);
        }

        let Some(d) = self.decor else {
            self.tick += 1;
            return true;
        };
        // belt: items ride left to right through build and flourish, then
        // smoothly decelerate to a halt during final shutdown
        let phase = if wipe > i64::MIN && self.shutdown_frames > 0 {
            let sd = (t - down).clamp(0, self.shutdown_frames);
            let s_max = self.shutdown_frames.max(1);
            let extra = (s_max * sd - sd * sd / 2) / (s_max * self.step.max(1));
            down / self.step + extra
        } else {
            t / self.step
        };
        let done = self.placed >= self.built;
        let (span_l, span_r) = self.text_span;
        let span_w = (span_r - span_l + 1).max(1);
        let rail_pulse_col = if done && wipe == i64::MIN {
            Some(span_l + (phase * 2).rem_euclid(span_w + 16) - 4)
        } else {
            None
        };
        for &(slot, column, moving) in &self.belt {
            if column < wipe {
                e.set_visible(slot, false);
                continue;
            }
            if moving {
                let v = match (column - phase).rem_euclid(12) {
                    0 => d.belt_open,
                    1 => d.belt_close,
                    _ if column % 3 == 0 => d.belt_arrow,
                    _ => d.belt_plain,
                };
                e.set_visual(slot, v);
            } else if let Some(pc) = rail_pulse_col {
                let v = if column >= span_l && column <= span_r && (column - pc).abs() <= 1 {
                    d.rail_pulse
                } else if column % 6 == 0 {
                    d.rail_post
                } else {
                    d.rail_plain
                };
                e.set_visual(slot, v);
            }
            e.set_visible(slot, true);
        }
        for &(slot, column) in &self.fixtures {
            e.set_visible(slot, column >= wipe);
        }

        // circuit lights: blinking red/amber while building, breathing bright
        // green when ONLINE
        let blink_step = t / (6 * self.step).max(1);
        let pulse_bright = (t / (10 * self.step).max(1)) % 2 == 0;
        for (k, &(slot, column)) in self.lights.iter().enumerate() {
            let v = if done {
                if pulse_bright {
                    d.light_green_bright
                } else {
                    d.light_green
                }
            } else if (blink_step + k as i64) % 2 == 0 {
                d.light_red
            } else {
                d.light_amber
            };
            e.set_visual(slot, v);
            e.set_visible(slot, column >= wipe);
        }

        // status bar: live build progress bar -> crisp green ONLINE indicator
        let filled = if self.built > 0 {
            (self.placed * self.status_slots.len()) / self.built
        } else {
            self.status_slots.len()
        };
        for (k, &(slot, column)) in self.status_slots.iter().enumerate() {
            let v = if done {
                d.online_chars[k]
            } else if k < filled {
                d.prog_filled
            } else {
                d.prog_empty
            };
            e.set_visual(slot, v);
            e.set_visible(slot, column >= wipe);
        }

        // right-side circuit activity meter pips
        let meter_tick = t / (4 * self.step).max(1);
        for (k, &(slot, column)) in self.meter_slots.iter().enumerate() {
            let v = if done {
                let lvl = ((meter_tick + k as i64) % 4) as usize;
                d.meter_levels[lvl]
            } else if (meter_tick + k as i64) % 3 == 0 {
                d.prog_filled
            } else {
                d.meter_idle
            };
            e.set_visual(slot, v);
            e.set_visible(slot, column >= wipe);
        }
        self.tick += 1;
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
        config: FactorioConfig,
    }

    fn config(args: &[&str]) -> FactorioConfig {
        let mut argv = vec!["factorio"];
        argv.extend_from_slice(args);
        Cli::parse_from(argv).config
    }

    fn strip_ansi(s: &str) -> String {
        let mut out = String::new();
        let mut chars = s.chars();
        while let Some(c) = chars.next() {
            if c == '\x1b' {
                for c in chars.by_ref() {
                    if c.is_ascii_alphabetic() {
                        break;
                    }
                }
            } else {
                out.push(c);
            }
        }
        out
    }

    /// Run to completion; the frame count and the last frame as text.
    fn run(
        input: &str,
        args: &[&str],
        width: i64,
        height: i64,
        handling: ExistingColorHandling,
        seed: u64,
    ) -> (usize, String, Vec<String>) {
        run_at(input, args, width, height, handling, seed, 60)
    }

    fn run_at(
        input: &str,
        args: &[&str],
        width: i64,
        height: i64,
        handling: ExistingColorHandling,
        seed: u64,
        fps: i64,
    ) -> (usize, String, Vec<String>) {
        let terminal = TerminalConfig {
            canvas_width: width,
            canvas_height: height,
            existing_color_handling: handling,
            ignore_terminal_dimensions: true,
            frame_rate: fps,
            ..TerminalConfig::default()
        };
        let mut e = match Engine::new(
            input,
            terminal,
            Rng::seeded(seed),
            Clock::virtual_with_frame_rate(fps),
        ) {
            // the CLI stops empty input before any effect ("NO INPUT.")
            Err(_) if input.trim().is_empty() => return (0, String::new(), Vec::new()),
            engine => engine.unwrap(),
        };
        let mut fx = Factorio::new(config(args));
        fx.build(&mut e).unwrap();
        let mut frames = Vec::new();
        while fx.next_frame(&mut e) {
            e.render_here();
            let mut parts = Vec::new();
            e.renderer().frame_parts(b"", b"", &mut parts);
            let bytes: Vec<u8> = parts.iter().flat_map(|p| p.iter().copied()).collect();
            frames.push(String::from_utf8(bytes).unwrap());
            assert!(frames.len() < 1_000_000, "effect does not end");
        }
        let last = frames.last().cloned().unwrap_or_default();
        (frames.len(), strip_ansi(&last), frames)
    }

    fn plain(text: &str) -> String {
        text.lines()
            .map(str::trim_end)
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn builds_the_text_and_ends_on_it() {
        let input = "OMARCHY\nhello world";
        let (n, last, frames) = run(input, &[], 40, 12, ExistingColorHandling::Ignore, 1);
        assert!(n > 100);
        assert_eq!(plain(&last).trim_matches('\n'), input);
        // the factory is on screen mid-build
        let mid = strip_ansi(&frames[n / 20]);
        assert!(mid.contains('='), "belt missing: {mid}");
    }

    #[test]
    fn timing_options_change_the_length() {
        let base = run("abc def", &[], 30, 8, ExistingColorHandling::Ignore, 1).0;
        for args in [
            &["--place-delay", "5"][..],
            &["--cool-frames", "30"],
            &["--hold-frames", "7"],
            &["--inserters", "3"],
            &["--lift-frames", "4"],
            &["--cycles", "2"],
        ] {
            let n = run("abc def", args, 30, 8, ExistingColorHandling::Ignore, 1).0;
            assert_ne!(n, base, "{args:?}");
        }
    }

    #[test]
    fn deterministic_for_a_seed() {
        let a = run(
            "random order\nfactory",
            &["--build-order", "random"],
            30,
            8,
            ExistingColorHandling::Ignore,
            7,
        )
        .2;
        let b = run(
            "random order\nfactory",
            &["--build-order", "random"],
            30,
            8,
            ExistingColorHandling::Ignore,
            7,
        )
        .2;
        assert_eq!(a, b);
    }

    #[test]
    fn edge_cases_end() {
        let long = "x".repeat(5000);
        let cases: &[(&str, i64, i64)] = &[
            ("", 20, 5),
            ("   \n  ", 20, 5),
            ("Z", 20, 5),
            ("Z", 1, 1),
            (&long, 80, 10),
            ("OMARCHY", 10, 3),
            ("wide 漢字 ok\n日本", 30, 6),
            ("big\ntext", 400, 120),
        ];
        for &(input, w, h) in cases {
            for order in ["columns", "reading", "trace", "random"] {
                run(
                    input,
                    &["--build-order", order],
                    w,
                    h,
                    ExistingColorHandling::Ignore,
                    3,
                );
            }
        }
        let (_, last, _) = run("Z", &[], 20, 5, ExistingColorHandling::Ignore, 3);
        assert_eq!(last.trim(), "Z");
    }

    #[test]
    fn dynamic_ends_on_input_colors() {
        let input = "\x1b[38;2;255;0;0mR\x1b[0m G";
        let (_, last, frames) = run(input, &[], 20, 6, ExistingColorHandling::Dynamic, 1);
        assert!(last.contains("R G"));
        assert!(frames.last().unwrap().contains("38;2;255;0;0"));
        let (_, _, frames) = run(input, &[], 20, 6, ExistingColorHandling::Ignore, 1);
        assert!(!frames.last().unwrap().contains("38;2;255;0;0"));
        // background-colored spaces are built (shown before the last frame)
        let input = "\x1b[41m   \x1b[0mX";
        let (n, last, frames) = run(input, &[], 20, 6, ExistingColorHandling::Dynamic, 1);
        assert!(last.contains("   X"));
        let red = "48;2;128;0;0";
        assert!(frames[..n - 1].iter().any(|f| f.contains(red)));
        assert!(frames.last().unwrap().contains(red));
        // hot spaces glow as a background (once the feed moves off them)
        let (_, _, frames) = run(
            input,
            &["--cool-frames", "30"],
            20,
            6,
            ExistingColorHandling::Dynamic,
            1,
        );
        assert!(frames.iter().any(|f| f.contains("48;2;221;161;59")));
    }

    #[test]
    fn trace_visits_every_cell_once() {
        let input = "#.#\n###\n..#\n#..";
        let (_, last, _) = run(
            input,
            &["--build-order", "trace"],
            10,
            10,
            ExistingColorHandling::Ignore,
            1,
        );
        assert_eq!(plain(&last).trim_matches('\n'), input);
    }

    const LOGO: &str = "                 ▄▄▄\n\
 ▄█████▄    ▄███████████▄    ▄███████   ▄███████   ▄███████   ▄█   █▄    ▄█   █▄\n\
███   ███  ███   ███   ███  ███   ███  ███   ███  ███   ███  ███   ███  ███   ███\n\
███   ███  ███   ███   ███  ███   ███  ███   ███  ███   █▀   ███   ███  ███   ███\n\
███   ███  ███   ███   ███ ▄███▄▄▄███ ▄███▄▄▄██▀  ███       ▄███▄▄▄███▄ ███▄▄▄███\n\
███   ███  ███   ███   ███ ▀███▀▀▀███ ▀███▀▀▀▀    ███      ▀▀███▀▀▀███  ▀▀▀▀▀▀███\n\
███   ███  ███   ███   ███  ███   ███ ██████████  ███   █▄   ███   ███  ▄██   ███\n\
███   ███  ███   ███   ███  ███   ███  ███   ███  ███   ███  ███   ███  ███   ███\n\
 ▀█████▀    ▀█   ███   █▀   ███   █▀   ███   ███  ███████▀   ███   █▀    ▀█████▀\n\
                                       ███   █▀";

    #[test]
    fn logo_runs_8_to_25_seconds_at_120_fps() {
        let (n, last, _) = run_at(LOGO, &[], 96, 24, ExistingColorHandling::Ignore, 7, 120);
        assert!((8 * 120..=25 * 120).contains(&n), "{n} frames");
        let want: Vec<&str> = LOGO.lines().map(str::trim_end).collect();
        let got: Vec<String> = plain(&last)
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| l.trim_end().to_string())
            .collect();
        let indent = got[0].len() - want[0].len();
        for (g, w) in got.iter().zip(&want) {
            assert_eq!(&g[indent.min(g.len())..], *w);
        }
    }

    #[test]
    fn gantries_split_between_glyphs() {
        let terminal = TerminalConfig {
            canvas_width: 40,
            canvas_height: 10,
            ignore_terminal_dimensions: true,
            ..TerminalConfig::default()
        };
        let input = "AA BB CCCC\nAA BB CCCC";
        let mut e =
            Engine::new(input, terminal, Rng::seeded(1), Clock::virtual_with_frame_rate(60)).unwrap();
        let mut fx = Factorio::new(config(&["--inserters", "2"]));
        fx.build(&mut e).unwrap();
        let symbols: Vec<String> = fx
            .gantries
            .iter()
            .map(|g| {
                let mut s: Vec<String> = g
                    .launches
                    .iter()
                    .map(|l| e.symbol(e.input_sym(l.slot)).to_string())
                    .collect();
                s.dedup();
                s.join("")
            })
            .collect();
        assert_eq!(symbols, ["AB", "C"]);
    }

    #[test]
    fn characters_rise_from_the_belt() {
        // mid build, an input character shows on a row of no input character
        let (_, last, frames) = run("X\nX\nX", &[], 10, 10, ExistingColorHandling::Ignore, 1);
        let home: Vec<usize> = last
            .lines()
            .enumerate()
            .filter(|(_, l)| l.contains('X'))
            .map(|(i, _)| i)
            .collect();
        assert_eq!(home.len(), 3);
        let away = frames.iter().any(|f| {
            strip_ansi(f)
                .lines()
                .enumerate()
                .any(|(i, l)| l.contains('X') && !home.contains(&i))
        });
        assert!(away);
    }
}
