//! fishing: fishing hooks catch swimming characters and reel them into their
//! final text positions.
//!
//! Original effect by Tushar Malpani (@tusharmalpani20),
//! https://github.com/tusharmalpani20/tte-community-effects, MIT.
//! (Python TerminalTextEffects plugin `effect_fishing.py`,
//! ChrisBuilds/terminaltexteffects#74.)
//!
//! The top row is a rolling water surface (when the text leaves it free).
//! The text is cut into hauls: each vertical run of glyphs in a text column
//! (at most eight). A haul's glyphs start as a small school of fish, in the
//! water colors, somewhere outside the text rows while there is room, and
//! sway side to side together. Hooks (`J` on a `|` line from the surface)
//! rest on the surface spread across the width. A hook casts along the
//! surface and down to a fish of the nearest haul in its share of the text,
//! the fish bites (a wiggle and a ripple), and the hook moves on to the next
//! fish of the school, stringing them on the line bottom glyph first, so the
//! string hangs in the run's own order. With the whole run on the line it
//! reels up under the surface, carries the string across, lowers it onto its
//! place and lets go: the run lands at once, flashes in the line color and
//! settles into the final gradient. A hook with nothing left in its share
//! takes the nearest haul from the busiest hook, so the hooks finish
//! together. Once per hook, with `--wrong-catch-chance`, a hook snags a junk
//! symbol next to its first fish, shakes it off and retries. When the last
//! hook has reeled out the top surface calms from the middle outward while a
//! gentle lake waterline blooms beneath the finished logo: a red-and-white
//! bobber floats on the rolling block-element swell, a bright fish leaps out
//! of the water and splashes back in to rock the bobber, and the lake
//! subsides cleanly back to the plain logo.
//!
//! `--hook-count 0` (the default) sizes the crew from the work: roughly the
//! total travel of all hauls over a fixed per-hook share, at least 3 and at
//! most one hook per 8 columns. Landed text sits above the lines and fish.

use clap::Args;

use crate::cli::parse_color;
use crate::effects::common::{
    parse_gradient_direction, parse_gradient_steps, parse_non_negative_int,
    parse_non_negative_ratio, parse_positive_float,
};
use crate::engine::animation::ExistingColorHandling;
use crate::engine::error::EngineError;
use crate::engine::terminal::{CharacterFilter, CharacterSort};
use crate::fx::run::Effect;
use crate::fx::{Engine, Hooks, Name, Sym, NONE};
use crate::utils::easing::Easing;
use crate::utils::geometry::Coord;
use crate::utils::graphics::{Color, ColorPair, Gradient, GradientDirection};
use crate::utils::pycompat::round_half_even;

#[derive(Args, Debug, Clone)]
pub struct FishingConfig {
    /// Maximum number of fishing hooks working concurrently. 0 (the default)
    /// sizes the crew from the work (text size and travel), at least 3 and
    /// at most one hook per 6 columns, so a big logo is reeled in about as
    /// fast as a short word.
    #[arg(long = "hook-count", default_value_t = 0, value_parser = parse_non_negative_int)]
    pub hook_count: i64,

    /// Color used for fishing lines and hooks.
    #[arg(long = "line-color", default_value = "D6F6FF", value_parser = parse_color)]
    pub line_color: Color,

    /// Colors used while input characters swim before being caught.
    #[arg(long = "water-colors", num_args = 1.., value_parser = parse_color,
          default_values = ["0B7285", "1098AD", "66D9E8"])]
    pub water_colors: Vec<Color>,

    /// Speed at which hooks slide and cast toward swimming characters.
    #[arg(long = "cast-speed", default_value_t = 0.75, value_parser = parse_positive_float)]
    pub cast_speed: f64,

    /// Speed used while reeling catches and returning hooks.
    #[arg(long = "reel-speed", default_value_t = 1.25, value_parser = parse_positive_float)]
    pub reel_speed: f64,

    /// Frames between casts and between each hook's initial start.
    #[arg(long = "cast-delay", default_value_t = 4, value_parser = parse_non_negative_int)]
    pub cast_delay: i64,

    /// One-time probability that each hook catches harmless junk before a real target.
    #[arg(long = "wrong-catch-chance", default_value_t = 0.05, value_parser = parse_non_negative_ratio)]
    pub wrong_catch_chance: f64,

    /// Space separated, unquoted, list of colors for the character gradient.
    #[arg(long = "final-gradient-stops", num_args = 1.., value_parser = parse_color,
          default_values = ["1E90FF", "00D1B2", "FFE66D"])]
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

const BITE_FRAMES: i64 = 4;
const RELEASE_FRAMES: i64 = 3;
const WRONG_SHAKE_FRAMES: i64 = 4;
const FINAL_HOLD_FRAMES: u32 = 6;
const SWIM_HOLD: i64 = 3;
/// The longest run of glyphs one hook carries at once.
const MAX_HAUL: usize = 8;
/// Frames a landed glyph takes to settle from the line color into its own.
const SETTLE_FRAMES: i64 = 12;
/// Frames the surface takes to calm from the middle out to the edges.
const CALM_FRAMES: i64 = 24;
/// Landed text stays above lines, fish, ripples and the surface.
const LANDED_LAYER: i32 = 1000;
const RIPPLE_LAYER: i32 = 900;
const FLOURISH_WATER_LAYER: i32 = 920;
const FLOURISH_ACTOR_LAYER: i32 = 950;
/// Duration of the post-logo lake/bobber/jumping-fish flourish (frames at 120 fps).
const FLOURISH_DURATION: i64 = 408;
/// `--hook-count 0` gives every hook about this much travel (cells).
const AUTO_WORK: f64 = 1000.0;

/// No effect callbacks: chained paths are engine actions.
struct NoHooks;
impl Hooks for NoHooks {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Waiting,
    Casting,
    Biting,
    Reeling,
    Transporting,
    Lowering,
    Releasing,
    WrongCatch,
    Returning,
    Leaving,
    Finished,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WrongStage {
    None,
    Reeling,
    Shaking,
}

/// One vertical run of glyphs in a text column, caught as one string.
struct Haul {
    /// Catch order: the bottom glyph first, so the last one caught (the top
    /// glyph) hangs right under the hook.
    order: Vec<u32>,
    column: i64,
    top_row: i64,
    /// Where the school starts.
    school: Coord,
}

struct Hook {
    hook: u32,
    lines: Vec<u32>,
    /// Line cells currently shown, and the hook coordinate they were laid
    /// out for (resynced only when the hook moves).
    line_shown: usize,
    line_coord: Coord,
    /// Hauls (indices) in this hook's share of the text.
    queue: Vec<usize>,
    haul: Option<usize>,
    /// The next index into the haul's catch order.
    next: usize,
    /// Glyphs on the line, nearest the hook first.
    chain: Vec<u32>,
    phase: Phase,
    target: Option<u32>,
    delay: i64,
    bite_ticks: i64,
    bite_origin: Option<Coord>,
    release_ticks: i64,
    wrong_pending: bool,
    junk: Option<u32>,
    casting_junk: bool,
    wrong_stage: WrongStage,
    wrong_ticks: i64,
    /// Reusable paths: cast, reel (also wrong reel, return, leave),
    /// transport, lower.
    cast_path: u32,
    reel_path: u32,
    transport_path: u32,
    lower_path: u32,
}

struct SplashDrop {
    slot: u32,
    origin_x: f64,
    origin_y: f64,
    vx: f64,
    vy: f64,
    start_frame: i64,
    duration: i64,
    sym_idx: usize,
}

struct Flourish {
    enabled: bool,
    started: bool,
    frame: i64,
    duration: i64,
    water_row: i64,
    left_col: i64,
    right_col: i64,
    has_reflect: bool,
    has_fish: bool,
    water_slots: Vec<u32>,
    reflect_slots: Vec<u32>,
    bobber_slot: Option<u32>,
    bobber_line_slots: Vec<u32>,
    fish_slots: [Option<u32>; 4],
    drops: Vec<SplashDrop>,
    bobber_col: i64,
    fish_start_x: f64,
    fish_end_x: f64,
    fish_arc_height: f64,
    fish_launch_frame: i64,
    fish_land_frame: i64,
    wave_blocks: [Sym; 5],
    reflect_syms: [Sym; 3],
    bobber_up: Sym,
    bobber_mid: Sym,
    line_sym: Sym,
    line_tip: Sym,
    fish_tail_flat: Sym,
    fish_tail_up: Sym,
    fish_tail_down: Sym,
    fish_body: Sym,
    fish_head_flat: Sym,
    fish_head_up: Sym,
    fish_head_down: Sym,
    drop_syms: [Sym; 4],
    foam_color: Color,
    bobber_red: Color,
    bobber_white: Color,
    fish_body_color: Color,
    fish_fin_color: Color,
    fish_glint_color: Color,
}

impl Flourish {
    fn empty() -> Self {
        Self {
            enabled: false,
            started: false,
            frame: 0,
            duration: FLOURISH_DURATION,
            water_row: 0,
            left_col: 0,
            right_col: 0,
            has_reflect: false,
            has_fish: false,
            water_slots: Vec::new(),
            reflect_slots: Vec::new(),
            bobber_slot: None,
            bobber_line_slots: Vec::new(),
            fish_slots: [None; 4],
            drops: Vec::new(),
            bobber_col: 0,
            fish_start_x: 0.0,
            fish_end_x: 0.0,
            fish_arc_height: 0.0,
            fish_launch_frame: 108,
            fish_land_frame: 204,
            wave_blocks: [Sym(NONE); 5],
            reflect_syms: [Sym(NONE); 3],
            bobber_up: Sym(NONE),
            bobber_mid: Sym(NONE),
            line_sym: Sym(NONE),
            line_tip: Sym(NONE),
            fish_tail_flat: Sym(NONE),
            fish_tail_up: Sym(NONE),
            fish_tail_down: Sym(NONE),
            fish_body: Sym(NONE),
            fish_head_flat: Sym(NONE),
            fish_head_up: Sym(NONE),
            fish_head_down: Sym(NONE),
            drop_syms: [Sym(NONE); 4],
            foam_color: Color::from_rgb(0xE0, 0xFB, 0xFF),
            bobber_red: Color::from_rgb(0xFF, 0x4D, 0x5A),
            bobber_white: Color::from_rgb(0xF5, 0xF9, 0xFF),
            fish_body_color: Color::from_rgb(0xFF, 0xB7, 0x03),
            fish_fin_color: Color::from_rgb(0xFB, 0x7A, 0x1E),
            fish_glint_color: Color::from_rgb(0xFF, 0xF3, 0xB0),
        }
    }

    fn build(e: &mut Engine, line_color: Color, has_catchable: bool) -> Self {
        let mut f = Self::empty();
        let canvas = &e.canvas;
        let gap = canvas.text_bottom - canvas.bottom;
        if !has_catchable || gap < 1 || canvas.width < 8 {
            return f;
        }

        let water_row = if gap >= 9 {
            canvas.text_bottom - 6
        } else if gap >= 7 {
            canvas.text_bottom - 5
        } else if gap >= 5 {
            canvas.text_bottom - 4
        } else if gap >= 3 {
            canvas.text_bottom - 2
        } else if gap == 2 {
            canvas.text_bottom - 2
        } else {
            canvas.bottom
        };
        let water_row = water_row.clamp(canvas.bottom, canvas.text_bottom - 1);

        let text_w = (canvas.text_right - canvas.text_left + 1).max(1);
        let pad = ((canvas.width - text_w) / 6).clamp(3, 18);
        let left_col = (canvas.text_left - pad).max(canvas.left);
        let right_col = (canvas.text_right + pad).min(canvas.right);
        let lake_w = (right_col - left_col + 1).max(1);
        if lake_w < 6 {
            return f;
        }

        let air_rows = (canvas.text_bottom - 1 - water_row).max(0);
        let has_reflect = water_row > canvas.bottom;
        let has_fish = air_rows >= 2 && lake_w >= 16;

        f.enabled = true;
        f.water_row = water_row;
        f.left_col = left_col;
        f.right_col = right_col;
        f.has_reflect = has_reflect;
        f.has_fish = has_fish;
        f.foam_color = lerp_color(line_color, Color::from_rgb(0xFF, 0xFF, 0xFF), 0.35);

        f.wave_blocks = [e.sym("▁"), e.sym("▂"), e.sym("▃"), e.sym("▄"), e.sym("▅")];
        f.reflect_syms = [e.sym("▔"), e.sym("▀"), e.sym("·")];
        f.bobber_up = e.sym("▀");
        f.bobber_mid = e.sym("▄");
        f.line_sym = e.sym("│");
        f.line_tip = e.sym("╷");
        f.fish_tail_flat = e.sym(">");
        f.fish_tail_up = e.sym("▗");
        f.fish_tail_down = e.sym("▝");
        f.fish_body = e.sym("▆");
        f.fish_head_flat = e.sym("▸");
        f.fish_head_up = e.sym("▝");
        f.fish_head_down = e.sym("▾");
        f.drop_syms = [e.sym("▘"), e.sym("▝"), e.sym("°"), e.sym("·")];

        let lake_center = (left_col + right_col) as f64 / 2.0;
        f.bobber_col = (lake_center + lake_w as f64 * 0.24)
            .round()
            .clamp((left_col + 2) as f64, (right_col - 2) as f64) as i64;

        let jump_span = (lake_w as f64 * 0.28).clamp(10.0, 26.0);
        let gap_to_bobber = (lake_w as f64 * 0.14).clamp(5.0, 13.0);
        f.fish_end_x = (f.bobber_col as f64 - gap_to_bobber)
            .max(left_col as f64 + 6.0)
            .min(right_col as f64 - 2.0);
        f.fish_start_x = (f.fish_end_x - jump_span).max(left_col as f64 + 2.0);
        f.fish_arc_height = (air_rows as f64 - 0.25).clamp(1.6, 4.4);
        f.fish_launch_frame = 104;
        f.fish_land_frame = 200;

        // Waterline slots (initially hidden)
        for col in left_col..=right_col {
            let slot = e.add_character_sym(f.wave_blocks[0], Coord::new(col, water_row));
            e.set_layer(slot, FLOURISH_WATER_LAYER);
            e.set_visible(slot, false);
            f.water_slots.push(slot);
        }

        // Reflection row just below waterline (initially hidden)
        if has_reflect {
            for col in left_col..=right_col {
                let slot = e.add_character_sym(f.reflect_syms[0], Coord::new(col, water_row - 1));
                e.set_layer(slot, FLOURISH_WATER_LAYER - 1);
                e.set_visible(slot, false);
                f.reflect_slots.push(slot);
            }
        }

        // Bobber + short slack line (strictly below text_bottom)
        let bobber = e.add_character_sym(f.bobber_up, Coord::new(f.bobber_col, water_row));
        e.set_layer(bobber, FLOURISH_ACTOR_LAYER + 2);
        e.set_visible(bobber, false);
        f.bobber_slot = Some(bobber);

        let line_cells = (air_rows - 1).clamp(0, 2) as usize;
        for i in 0..line_cells {
            let sym = if i == 0 { f.line_tip } else { f.line_sym };
            let slot = e.add_character_sym(sym, Coord::new(f.bobber_col, water_row + 1 + i as i64));
            e.set_layer(slot, FLOURISH_ACTOR_LAYER);
            e.set_visible(slot, false);
            f.bobber_line_slots.push(slot);
        }

        // Jumping fish (4 cells: tail, rear body, front body, head) + splash droplets
        if has_fish {
            for i in 0..4 {
                let slot = e.add_character_sym(f.fish_body, Coord::new(left_col, water_row));
                e.set_layer(slot, FLOURISH_ACTOR_LAYER + 4);
                e.set_visible(slot, false);
                f.fish_slots[i] = Some(slot);
            }

            // Launch splash (3 small droplets)
            let launch_specs: [(f64, f64, i64, usize); 3] = [
                (-0.14, 0.14, 34, 0),
                (0.06, 0.17, 36, 2),
                (0.18, 0.13, 32, 1),
            ];
            for (vx, vy, dur, sym_idx) in launch_specs {
                let slot = e.add_character_sym(f.drop_syms[sym_idx], Coord::new(left_col, water_row));
                e.set_layer(slot, FLOURISH_ACTOR_LAYER + 3);
                e.set_visible(slot, false);
                f.drops.push(SplashDrop {
                    slot,
                    origin_x: f.fish_start_x,
                    origin_y: water_row as f64 + 0.5,
                    vx,
                    vy,
                    start_frame: f.fish_launch_frame,
                    duration: dur,
                    sym_idx,
                });
            }

            // Re-entry splash (6 lively droplets)
            let land_specs: [(f64, f64, i64, usize); 6] = [
                (-0.26, 0.21, 50, 0),
                (-0.15, 0.26, 56, 2),
                (-0.04, 0.29, 58, 3),
                (0.07, 0.27, 56, 2),
                (0.18, 0.23, 52, 1),
                (0.28, 0.18, 46, 3),
            ];
            for (vx, vy, dur, sym_idx) in land_specs {
                let slot = e.add_character_sym(f.drop_syms[sym_idx], Coord::new(left_col, water_row));
                e.set_layer(slot, FLOURISH_ACTOR_LAYER + 3);
                e.set_visible(slot, false);
                f.drops.push(SplashDrop {
                    slot,
                    origin_x: f.fish_end_x,
                    origin_y: water_row as f64 + 0.5,
                    vx,
                    vy,
                    start_frame: f.fish_land_frame,
                    duration: dur,
                    sym_idx,
                });
            }
        }

        f
    }

    fn is_done(&self) -> bool {
        !self.enabled || (self.started && self.frame >= self.duration)
    }

    fn ripple_at(&self, col: f64, frame: i64) -> (f64, f64) {
        let mut disp = 0.0;
        let mut foam = 0.0;
        if self.has_fish {
            // Launch ripple
            let dt_l = (frame - self.fish_launch_frame) as f64;
            if dt_l >= 0.0 {
                let dist = (col - self.fish_start_x).abs();
                let wave_t = dt_l - dist / 0.26;
                if (0.0..34.0).contains(&wave_t) {
                    let env = (-wave_t * 0.09).exp() * (-dist * 0.045).exp();
                    disp += 0.55 * env * (wave_t * 0.5).cos();
                    foam += 0.5 * env;
                }
            }
            // Re-entry splash ripple (stronger, travels to bobber)
            let dt_r = (frame - self.fish_land_frame) as f64;
            if dt_r >= 0.0 {
                let dist = (col - self.fish_end_x).abs();
                let wave_t = dt_r - dist / 0.28;
                if (0.0..52.0).contains(&wave_t) {
                    let env = (-wave_t * 0.065).exp() * (-dist * 0.025).exp();
                    disp += 1.05 * env * (wave_t * 0.45).cos();
                    foam += 0.9 * env;
                }
            }
        }
        (disp, foam.clamp(0.0, 1.0))
    }

    fn step(&mut self, e: &mut Engine, water: &[Color], line_color: Color) {
        if !self.enabled {
            return;
        }
        self.started = true;
        let t = self.frame;
        self.frame += 1;
        if t >= self.duration {
            return;
        }

        let black = Color::from_rgb(0, 0, 0);
        let deep = water[0];
        let mid = water[water.len() / 2];
        let bright = *water.last().expect("water");
        let text_bottom = e.canvas.text_bottom;
        let lake_center = (self.left_col + self.right_col) as f64 / 2.0;
        let half_w = ((self.right_col - self.left_col) as f64 / 2.0).max(1.0);

        let bloom_frames = 48.0;
        let fade_start = (self.duration - 64) as f64;
        let fade_len = 64.0;
        let tf = t as f64;

        // 1. Waterline (block-element rolling waves + splash ripples)
        for (i, &slot) in self.water_slots.iter().enumerate() {
            let col = self.left_col + i as i64;
            let x = col as f64;
            let norm_dist = ((x - lake_center).abs() / half_w).clamp(0.0, 1.0);

            // Bloom outward from center, fade inward from edges
            let in_env = ((tf - norm_dist * 24.0) / (bloom_frames - 24.0)).clamp(0.0, 1.0);
            let out_env = if tf < fade_start {
                1.0
            } else {
                let edge_delay = (1.0 - norm_dist) * 26.0;
                1.0 - ((tf - fade_start - edge_delay) / (fade_len - 26.0)).clamp(0.0, 1.0)
            };
            let env = in_env * out_env;
            if env <= 0.02 {
                e.set_visible(slot, false);
                continue;
            }

            // Edge taper so ends of the lake feather naturally into ▁
            let edge_taper = (1.0 - norm_dist.powf(3.0)).clamp(0.18, 1.0);
            let swell = 0.56
                + 0.30 * (x * 0.20 - tf * 0.065).sin()
                + 0.20 * (x * 0.11 + tf * 0.038).sin();
            let (rip_disp, rip_foam) = self.ripple_at(x, t);
            let h = ((swell * edge_taper + rip_disp * 0.52) * env).clamp(0.0, 1.0);

            let idx = (h * 4.6).round().clamp(0.0, 4.0) as usize;
            let mut color = if h < 0.48 {
                lerp_color(deep, mid, h / 0.48)
            } else {
                lerp_color(mid, bright, (h - 0.48) / 0.52)
            };
            if h > 0.78 {
                color = lerp_color(color, self.foam_color, ((h - 0.78) / 0.22) * 0.35);
            }
            if rip_foam > 0.05 {
                color = lerp_color(color, self.foam_color, (rip_foam * 0.88).clamp(0.0, 0.88));
            }
            if env < 0.99 {
                color = lerp_color(black, color, env);
            }

            e.set_appearance(slot, Some(self.wave_blocks[idx]), Some(ColorPair::new(Some(color), None)));
            e.set_visible(slot, true);
        }

        // 2. Subtle reflection / depth row under the waterline (every 2nd frame)
        if self.has_reflect && (t % 2 == 0 || t == self.duration - 1) {
            let dim_deep = lerp_color(black, deep, 0.38);
            let dim_mid = lerp_color(black, mid, 0.52);
            for (i, &slot) in self.reflect_slots.iter().enumerate() {
                let col = self.left_col + i as i64;
                let x = col as f64;
                let norm_dist = ((x - lake_center).abs() / half_w).clamp(0.0, 1.0);
                let in_env = ((tf - 10.0 - norm_dist * 24.0) / 24.0).clamp(0.0, 1.0);
                let out_env = if tf < fade_start {
                    1.0
                } else {
                    let edge_delay = (1.0 - norm_dist) * 24.0;
                    1.0 - ((tf - fade_start - edge_delay) / (fade_len - 24.0)).clamp(0.0, 1.0)
                };
                let env = in_env * out_env * (1.0 - norm_dist * norm_dist);
                if env <= 0.05 {
                    e.set_visible(slot, false);
                    continue;
                }
                let glint = (x * 0.27 + tf * 0.045).sin() * (x * 0.13 - tf * 0.03).cos();
                let (sym, base_c) = if glint > 0.55 {
                    (self.reflect_syms[0], dim_mid)
                } else if glint > -0.15 {
                    (self.reflect_syms[0], dim_deep)
                } else {
                    (self.reflect_syms[2], dim_deep)
                };
                let color = lerp_color(black, base_c, env);
                e.set_appearance(slot, Some(sym), Some(ColorPair::new(Some(color), None)));
                e.set_visible(slot, true);
            }
        }

        // 3. Floating red-and-white bobber + delicate slack line
        if let Some(bobber) = self.bobber_slot {
            let bobber_in = ((tf - 20.0) / 18.0).clamp(0.0, 1.0);
            let bobber_out = if tf < fade_start - 8.0 {
                1.0
            } else {
                1.0 - ((tf - (fade_start - 8.0)) / 32.0).clamp(0.0, 1.0)
            };
            let b_env = bobber_in * bobber_out;

            if b_env <= 0.02 {
                e.set_visible(bobber, false);
                for &ls in &self.bobber_line_slots {
                    e.set_visible(ls, false);
                }
            } else {
                let bx = self.bobber_col as f64;
                let ambient = 0.30 * (bx * 0.20 - tf * 0.065).sin()
                    + 0.20 * (bx * 0.11 + tf * 0.038).sin();
                let (rip_disp, _) = self.ripple_at(bx, t);
                // Settle bounce when bobber first drops in
                let settle_t = (tf - 20.0).max(0.0);
                let settle = if settle_t < 36.0 {
                    -0.55 * (-settle_t * 0.11).exp() * (settle_t * 0.45).cos()
                } else {
                    0.0
                };
                let vertical = ambient + rip_disp * 0.95 + settle;

                // When floating high, sit on water_row + 1 (if room below logo);
                // when dipping in a trough or splash wave, dip into water_row!
                let can_float_above = self.water_row + 1 < text_bottom;
                let (bob_row, dipped) = if can_float_above && vertical > -0.18 {
                    (self.water_row + 1, false)
                } else {
                    (self.water_row, true)
                };

                let red = lerp_color(black, self.bobber_red, b_env);
                let white = lerp_color(black, self.bobber_white, b_env);
                let water_bg = lerp_color(black, mid, b_env * 0.85);
                let (sym, colors) = if !dipped {
                    // Crisp two-tone red-over-white floating cork
                    (self.bobber_up, ColorPair::new(Some(red), Some(white)))
                } else {
                    // Dipped into the wave: red top peeking out over water
                    (self.bobber_mid, ColorPair::new(Some(red), Some(water_bg)))
                };

                e.set_coordinate(bobber, Coord::new(self.bobber_col, bob_row));
                e.set_appearance(bobber, Some(sym), Some(colors));
                e.set_visible(bobber, true);

                let slack_color = lerp_color(black, line_color, b_env * 0.55);
                for (i, &ls) in self.bobber_line_slots.iter().enumerate() {
                    let lr = bob_row + 1 + i as i64;
                    if lr < text_bottom {
                        let lsym = if i == 0 { self.line_tip } else { self.line_sym };
                        e.set_coordinate(ls, Coord::new(self.bobber_col, lr));
                        e.set_appearance(ls, Some(lsym), Some(ColorPair::new(Some(slack_color), None)));
                        e.set_visible(ls, true);
                    } else {
                        e.set_visible(ls, false);
                    }
                }
            }
        }

        // 4. Jumping fish (parabolic arc with pitch & waterline clipping)
        if self.has_fish {
            if t >= self.fish_launch_frame && t <= self.fish_land_frame {
                let u = (t - self.fish_launch_frame) as f64
                    / (self.fish_land_frame - self.fish_launch_frame).max(1) as f64;
                let fx = self.fish_start_x + (self.fish_end_x - self.fish_start_x) * u;
                let fy = self.water_row as f64 + 4.0 * self.fish_arc_height * u * (1.0 - u);

                let cx = fx.round() as i64;
                let cy = fy.round() as i64;

                // Pitch posture: ascending, apex, diving (4-cell silhouette: tail, rear, front, head)
                let parts: [(i64, i64, Sym, Color); 4] = if u < 0.34 {
                    [
                        (cx - 2, cy - 1, self.fish_tail_up, self.fish_fin_color),
                        (cx - 1, cy - 1, self.fish_body, self.fish_body_color),
                        (cx, cy, self.fish_body, self.fish_body_color),
                        (cx + 1, cy, self.fish_head_flat, self.fish_glint_color),
                    ]
                } else if u <= 0.66 {
                    [
                        (cx - 2, cy, self.fish_tail_flat, self.fish_fin_color),
                        (cx - 1, cy, self.fish_body, self.fish_body_color),
                        (cx, cy, self.fish_body, self.fish_body_color),
                        (cx + 1, cy, self.fish_head_flat, self.fish_glint_color),
                    ]
                } else {
                    [
                        (cx - 2, cy + 1, self.fish_tail_down, self.fish_fin_color),
                        (cx - 1, cy + 1, self.fish_body, self.fish_body_color),
                        (cx, cy, self.fish_body, self.fish_body_color),
                        (cx + 1, cy - 1, self.fish_head_down, self.fish_glint_color),
                    ]
                };

                // Subtle specular glint at the apex of the leap
                let apex_glint = (1.0 - ((u - 0.5) * 4.0).abs()).clamp(0.0, 1.0);

                for (idx, (pc, pr, sym, base_col)) in parts.into_iter().enumerate() {
                    if let Some(slot) = self.fish_slots[idx] {
                        if pr > self.water_row
                            && pr < text_bottom
                            && pc >= e.canvas.left
                            && pc <= e.canvas.right
                        {
                            let col = if (idx == 1 || idx == 2) && apex_glint > 0.1 {
                                lerp_color(base_col, self.fish_glint_color, apex_glint * 0.55)
                            } else {
                                base_col
                            };
                            e.set_coordinate(slot, Coord::new(pc, pr));
                            e.set_appearance(slot, Some(sym), Some(ColorPair::new(Some(col), None)));
                            e.set_visible(slot, true);
                        } else {
                            e.set_visible(slot, false);
                        }
                    }
                }
            } else {
                for slot in self.fish_slots.into_iter().flatten() {
                    e.set_visible(slot, false);
                }
            }

            // 5. Splash droplets (ballistic arc clipped between water_row and text_bottom)
            let gravity = 0.0085;
            for d in &self.drops {
                let dt = t - d.start_frame;
                if dt < 0 || dt >= d.duration {
                    e.set_visible(d.slot, false);
                    continue;
                }
                let dtf = dt as f64;
                let px = (d.origin_x + d.vx * dtf).round() as i64;
                let py = (d.origin_y + d.vy * dtf - 0.5 * gravity * dtf * dtf).round() as i64;
                if py <= self.water_row
                    || py >= text_bottom
                    || px < e.canvas.left
                    || px > e.canvas.right
                {
                    e.set_visible(d.slot, false);
                    continue;
                }
                let life = dt as f64 / d.duration as f64;
                let color = if life < 0.45 {
                    lerp_color(self.foam_color, bright, life / 0.45)
                } else {
                    lerp_color(bright, deep, (life - 0.45) / 0.55)
                };
                let sym = if life > 0.72 {
                    self.drop_syms[3]
                } else {
                    self.drop_syms[d.sym_idx]
                };
                e.set_coordinate(d.slot, Coord::new(px, py));
                e.set_appearance(d.slot, Some(sym), Some(ColorPair::new(Some(color), None)));
                e.set_visible(d.slot, true);
            }
        }
    }
}

pub struct Fishing {
    config: FishingConfig,
    hooks: Vec<Hook>,
    hauls: Vec<Haul>,
    /// Final colors per slot (indexed by slot; input slots only).
    final_colors: Vec<ColorPair>,
    ripples: Vec<u32>,
    ripple_in_use: Vec<bool>,
    ripple_scene: Vec<u32>,
    junk_available: Vec<u32>,
    junk_color: Color,
    bang: Sym,
    water: Vec<Color>,
    /// The surface row, one cell per column (empty when the text needs the
    /// top row).
    surface: Vec<u32>,
    wave_syms: [Sym; 3],
    /// Landed glyphs still settling, with their frames left.
    settling: Vec<(u32, i64)>,
    /// Frames since the surface started calming.
    calm: Option<i64>,
    /// Post-logo signature flourish (lake, bobber, jumping fish & splash).
    flourish: Flourish,
    cleanup_done: bool,
    hold_left: u32,
    frames: u64,
}

impl Fishing {
    pub fn new(config: FishingConfig) -> Self {
        Fishing {
            config,
            hooks: Vec::new(),
            hauls: Vec::new(),
            final_colors: Vec::new(),
            ripples: Vec::new(),
            ripple_in_use: Vec::new(),
            ripple_scene: Vec::new(),
            junk_available: Vec::new(),
            junk_color: Color::from_rgb(0, 0, 0),
            bang: Sym(NONE),
            water: Vec::new(),
            surface: Vec::new(),
            wave_syms: [Sym(NONE); 3],
            settling: Vec::new(),
            calm: None,
            flourish: Flourish::empty(),
            cleanup_done: false,
            hold_left: 0,
            frames: 0,
        }
    }
}

impl Hooks for Fishing {}

fn other(message: String) -> EngineError {
    EngineError::Other(message)
}

fn in_canvas(e: &Engine, c: Coord) -> bool {
    e.canvas.coord_is_in_canvas(c)
}

/// The in-canvas cardinal neighbors (west, east, south, north).
fn neighbors(e: &Engine, c: Coord) -> Vec<Coord> {
    [(-1, 0), (1, 0), (0, -1), (0, 1)]
        .iter()
        .map(|&(dc, dr)| Coord::new(c.column + dc, c.row + dr))
        .filter(|&n| in_canvas(e, n))
        .collect()
}

/// Empty a reusable path, give it the waypoints (repeats dropped), and
/// activate it.
fn run_path(e: &mut Engine, slot: u32, path: u32, waypoints: &[Coord]) {
    e.path_reset(path);
    let mut last = e.coord(slot);
    let mut any = false;
    for &w in waypoints {
        if w == last {
            continue;
        }
        e.path_new_waypoint(path, w, None, Name::NONE)
            .expect("anonymous waypoint");
        last = w;
        any = true;
    }
    if !any {
        // already there: a one-waypoint path completes on its first step
        e.path_new_waypoint(path, last, None, Name::NONE)
            .expect("anonymous waypoint");
    }
    e.activate_path(&mut NoHooks, slot, path);
    e.active_insert(slot);
}

fn lerp_color(a: Color, b: Color, t: f64) -> Color {
    let (ar, ag, ab) = a.rgb_ints();
    let (br, bg, bb) = b.rgb_ints();
    let mix = |x: u8, y: u8| (x as f64 + (y as f64 - x as f64) * t).round().clamp(0.0, 255.0) as u8;
    Color::from_rgb(mix(ar, br), mix(ag, bg), mix(ab, bb))
}

impl Fishing {
    fn idle(e: &Engine, slot: u32) -> bool {
        e.ch.path[slot as usize] == NONE
    }

    fn sync_line(e: &mut Engine, hook: &mut Hook) {
        let coord = e.coord(hook.hook);
        if coord == hook.line_coord {
            return;
        }
        hook.line_coord = coord;
        let len = (e.canvas.top - coord.row).max(0) as usize;
        let len = len.min(hook.lines.len());
        for (i, &line) in hook.lines.iter().enumerate() {
            if i < len {
                e.set_coordinate(line, Coord::new(coord.column, coord.row + i as i64 + 1));
                e.set_visible(line, true);
            } else if i < hook.line_shown {
                e.set_visible(line, false);
            } else {
                break;
            }
        }
        hook.line_shown = len;
    }

    /// Hang the string (or the snagged junk) under the hook; cells below
    /// the canvas stay hidden until the string is lifted.
    fn sync_chain(e: &mut Engine, hook: &Hook) {
        let c = e.coord(hook.hook);
        let bottom = e.canvas.bottom;
        if hook.phase == Phase::WrongCatch {
            if let Some(junk) = hook.junk {
                e.set_coordinate(junk, Coord::new(c.column, (c.row - 1).max(bottom)));
            }
        }
        for (i, &slot) in hook.chain.iter().enumerate() {
            let row = c.row - 1 - i as i64;
            if row < bottom {
                e.set_visible(slot, false);
            } else {
                e.set_coordinate(slot, Coord::new(c.column, row));
                e.set_visible(slot, true);
            }
        }
    }

    /// The haul nearest this hook: from its own share, else from the share
    /// with the most hauls left.
    fn pick_haul(&mut self, e: &Engine, h: usize) -> Option<usize> {
        let column = e.coord(self.hooks[h].hook).column;
        let from = if !self.hooks[h].queue.is_empty() {
            h
        } else {
            let (busiest, size) = self
                .hooks
                .iter()
                .enumerate()
                .map(|(i, hook)| (i, hook.queue.len()))
                .max_by_key(|&(i, len)| (len, std::cmp::Reverse(i)))?;
            if size == 0 {
                return None;
            }
            busiest
        };
        // the longest trips first (so the crew does not end on a few far
        // schools), discounted by how far the hook must go to start one
        let (hauls, top) = (&self.hauls, e.canvas.top);
        let (at, _) = self.hooks[from]
            .queue
            .iter()
            .enumerate()
            .min_by_key(|&(_, &k)| {
                let haul = &hauls[k];
                let s = haul.school;
                let reach = (s.column - column).abs();
                let trip = 2 * (top - s.row) + (s.column - haul.column).abs() + (top - haul.top_row);
                (reach - trip, k)
            })?;
        Some(self.hooks[from].queue.swap_remove(at))
    }

    fn start_cast(&mut self, e: &mut Engine, h: usize) {
        let top = e.canvas.top;
        if self.hooks[h].haul.is_none() {
            match self.pick_haul(e, h) {
                Some(k) => {
                    let hook = &mut self.hooks[h];
                    hook.haul = Some(k);
                    hook.next = 0;
                }
                None => {
                    self.start_leaving(e, h);
                    return;
                }
            }
        }
        let k = self.hooks[h].haul.expect("haul");
        let hook = &mut self.hooks[h];
        if hook.target.is_none() {
            hook.target = Some(self.hauls[k].order[hook.next]);
        }
        let target = hook.target.expect("target");
        let first = hook.chain.is_empty();
        let target_coord = if first && hook.wrong_pending && !self.junk_available.is_empty() {
            let junk = self.junk_available.pop().expect("junk available");
            let around = e.coord(target);
            let options = neighbors(e, around);
            let junk_coord = if options.is_empty() {
                around
            } else {
                options[e.rng.choice_index(options.len())]
            };
            e.set_coordinate(junk, junk_coord);
            e.set_appearance(junk, None, Some(ColorPair::new(Some(self.junk_color), None)));
            e.set_visible(junk, true);
            hook.junk = Some(junk);
            hook.casting_junk = true;
            hook.wrong_pending = false;
            junk_coord
        } else {
            if first {
                hook.wrong_pending = false;
            }
            e.deactivate_path(target, None);
            e.coord(target)
        };
        let approach = Coord::new(target_coord.column, top.min(target_coord.row + 1));
        if first {
            // up to the surface, along it, and down to the fish
            let here = e.coord(hook.hook);
            let waypoints = [
                Coord::new(here.column, top),
                Coord::new(target_coord.column, top),
                approach,
            ];
            run_path(e, hook.hook, hook.cast_path, &waypoints);
        } else {
            // the string already on the line follows straight to the next
            run_path(e, hook.hook, hook.cast_path, &[approach]);
        }
        hook.phase = Phase::Casting;
    }

    fn start_wrong_catch(&mut self, e: &mut Engine, h: usize) {
        let top = e.canvas.top;
        let hook = &mut self.hooks[h];
        let c = e.coord(hook.hook);
        run_path(e, hook.hook, hook.reel_path, &[Coord::new(c.column, top.min(c.row + 2))]);
        hook.wrong_stage = WrongStage::Reeling;
        hook.phase = Phase::WrongCatch;
    }

    fn advance_wrong_catch(&mut self, e: &mut Engine, h: usize) {
        let hook = &mut self.hooks[h];
        let Some(junk) = hook.junk else {
            hook.wrong_stage = WrongStage::None;
            self.start_returning(e, h);
            return;
        };
        match hook.wrong_stage {
            WrongStage::Reeling if Self::idle(e, hook.hook) => {
                hook.wrong_stage = WrongStage::Shaking;
                hook.wrong_ticks = WRONG_SHAKE_FRAMES;
            }
            WrongStage::Shaking if hook.wrong_ticks != 0 => {
                let sym = if hook.wrong_ticks % 2 != 0 {
                    self.bang
                } else {
                    e.input_sym(junk)
                };
                e.set_appearance(junk, Some(sym), Some(ColorPair::new(Some(self.junk_color), None)));
                hook.wrong_ticks -= 1;
            }
            WrongStage::Shaking => {
                e.set_visible(junk, false);
                self.junk_available.push(junk);
                hook.junk = None;
                hook.casting_junk = false;
                hook.wrong_stage = WrongStage::None;
                self.start_returning(e, h);
            }
            _ => {}
        }
    }

    fn wiggle_target(e: &mut Engine, hook: &mut Hook) {
        let (Some(target), Some(origin)) = (hook.target, hook.bite_origin) else {
            hook.bite_ticks = 0;
            return;
        };
        let direction = if hook.bite_ticks % 2 == 0 { -1 } else { 1 };
        let horizontal = Coord::new(origin.column + direction, origin.row);
        if in_canvas(e, horizontal) {
            e.set_coordinate(target, horizontal);
        } else {
            let vertical = Coord::new(origin.column, origin.row + direction);
            let c = if in_canvas(e, vertical) { vertical } else { origin };
            e.set_coordinate(target, c);
        }
        hook.bite_ticks -= 1;
    }

    /// The fish is on: string it under the hook, then go for the next fish
    /// of the school or reel the whole string up.
    fn hook_fish(&mut self, e: &mut Engine, h: usize) {
        let hook = &mut self.hooks[h];
        let (Some(target), Some(k)) = (hook.target.take(), hook.haul) else {
            return;
        };
        if let Some(origin) = hook.bite_origin.take() {
            e.set_coordinate(target, origin);
        }
        let layer = e.layer(hook.hook) - 1;
        e.set_layer(target, layer);
        hook.chain.insert(0, target);
        hook.next += 1;
        if hook.next < self.hauls[k].order.len() {
            self.start_cast(e, h);
        } else {
            let hook = &mut self.hooks[h];
            let c = e.coord(hook.hook);
            run_path(e, hook.hook, hook.reel_path, &[Coord::new(c.column, e.canvas.top)]);
            hook.phase = Phase::Reeling;
        }
    }

    fn emit_ripple(&mut self, e: &mut Engine, coord: Coord) {
        let Some(i) = self.ripple_in_use.iter().position(|&used| !used) else {
            return;
        };
        let slot = self.ripples[i];
        self.ripple_in_use[i] = true;
        e.deactivate_path(slot, None);
        e.deactivate_scene(slot, None);
        e.set_coordinate(slot, coord);
        e.scene_reset(self.ripple_scene[i]);
        e.activate_scene(&mut NoHooks, slot, self.ripple_scene[i]);
        e.set_visible(slot, true);
        e.active_insert(slot);
    }

    fn start_transporting(&mut self, e: &mut Engine, h: usize) {
        let hook = &mut self.hooks[h];
        let Some(k) = hook.haul else {
            return;
        };
        let c = e.coord(hook.hook);
        let dest = Coord::new(self.hauls[k].column, c.row);
        run_path(e, hook.hook, hook.transport_path, &[dest]);
        hook.phase = Phase::Transporting;
    }

    fn start_lowering(&mut self, e: &mut Engine, h: usize) {
        let hook = &mut self.hooks[h];
        let Some(k) = hook.haul else {
            return;
        };
        let haul = &self.hauls[k];
        let release_row = e.canvas.top.min(haul.top_row + 1);
        run_path(e, hook.hook, hook.lower_path, &[Coord::new(haul.column, release_row)]);
        hook.phase = Phase::Lowering;
    }

    fn set_final_appearance(&self, e: &mut Engine, slot: u32) {
        e.deactivate_scene(slot, None);
        let colors = self.final_colors[slot as usize];
        let sym = e.input_sym(slot);
        e.set_appearance(slot, Some(sym), Some(colors));
    }

    /// Let the whole string go: every glyph lands on its own cell at once,
    /// in the line color, and settles into its final color.
    fn start_releasing(&mut self, e: &mut Engine, h: usize) {
        let flash = ColorPair::new(Some(self.config.line_color), None);
        let chain = std::mem::take(&mut self.hooks[h].chain);
        for slot in chain {
            e.deactivate_path(slot, None);
            let input = e.input_coord(slot);
            e.set_coordinate(slot, input);
            e.set_layer(slot, LANDED_LAYER);
            e.deactivate_scene(slot, None);
            let sym = e.input_sym(slot);
            e.set_appearance(slot, Some(sym), Some(flash));
            e.set_visible(slot, true);
            self.settling.push((slot, SETTLE_FRAMES));
        }
        let hook = &mut self.hooks[h];
        hook.release_ticks = RELEASE_FRAMES;
        hook.phase = Phase::Releasing;
    }

    /// After a wrong catch: reel the empty hook up and retry the same fish.
    fn start_returning(&mut self, e: &mut Engine, h: usize) {
        let top = e.canvas.top;
        let hook = &mut self.hooks[h];
        let c = e.coord(hook.hook);
        run_path(e, hook.hook, hook.reel_path, &[Coord::new(c.column, top)]);
        hook.phase = Phase::Returning;
    }

    /// Nothing left anywhere: reel up to the surface and out.
    fn start_leaving(&mut self, e: &mut Engine, h: usize) {
        let top = e.canvas.top;
        let hook = &mut self.hooks[h];
        let c = e.coord(hook.hook);
        run_path(e, hook.hook, hook.reel_path, &[Coord::new(c.column, top)]);
        hook.phase = Phase::Leaving;
    }

    fn finish(e: &mut Engine, hook: &mut Hook) {
        hook.phase = Phase::Finished;
        e.set_visible(hook.hook, false);
        for i in 0..hook.line_shown {
            e.set_visible(hook.lines[i], false);
        }
        hook.line_shown = 0;
        hook.line_coord = Coord::new(i64::MIN, i64::MIN);
    }

    fn step_settling(&mut self, e: &mut Engine) {
        let flash = self.config.line_color;
        let mut i = 0;
        while i < self.settling.len() {
            let (slot, left) = self.settling[i];
            let left = left - 1;
            if left <= 0 {
                self.set_final_appearance(e, slot);
                self.settling.swap_remove(i);
                continue;
            }
            self.settling[i].1 = left;
            if let Some(fg) = self.final_colors[slot as usize].fg_color {
                let t = 1.0 - left as f64 / SETTLE_FRAMES as f64;
                let colors = ColorPair::new(
                    Some(lerp_color(flash, fg, t * t * (3.0 - 2.0 * t))),
                    self.final_colors[slot as usize].bg_color,
                );
                let sym = e.input_sym(slot);
                e.set_appearance(slot, Some(sym), Some(colors));
            }
            i += 1;
        }
    }

    /// The rolling surface; while calming, each column fades `-`, `.`,
    /// gone, from the middle outward.
    fn step_surface(&mut self, e: &mut Engine) {
        if self.surface.is_empty() || (self.calm.is_none() && self.frames % 2 != 0) {
            return;
        }
        let t = self.frames as f64;
        let n = self.water.len();
        let center = e.canvas.center_column as f64;
        let half = (e.canvas.width as f64 / 2.0).max(1.0);
        let [tilde, dash, dot] = self.wave_syms;
        for &slot in &self.surface {
            let column = e.coord(slot).column;
            let x = column as f64;
            if let Some(calm) = self.calm {
                let threshold = ((x - center).abs() / half * CALM_FRAMES as f64) as i64;
                let step = calm - threshold;
                if step >= 6 {
                    e.set_visible(slot, false);
                    continue;
                }
                if step >= 0 {
                    let sym = if step >= 3 { dot } else { dash };
                    e.set_appearance(slot, Some(sym), Some(ColorPair::new(Some(self.water[0]), None)));
                    continue;
                }
            }
            let v = (x * 0.31 - t * 0.09).sin() + 0.5 * (x * 0.13 + t * 0.05).sin();
            let sym = if v > -0.6 { tilde } else { dash };
            let index = (((v + 1.5) / 3.0) * n as f64).floor().clamp(0.0, (n - 1) as f64) as usize;
            e.set_appearance(slot, Some(sym), Some(ColorPair::new(Some(self.water[index]), None)));
        }
    }

    fn cleanup(&mut self, e: &mut Engine) {
        for slot in e.added_chars.clone() {
            e.deactivate_path(slot, None);
            e.deactivate_scene(slot, None);
            e.set_visible(slot, false);
        }
        for slot in e.input_chars.clone() {
            e.deactivate_path(slot, None);
            let input = e.input_coord(slot);
            e.set_coordinate(slot, input);
            e.set_layer(slot, 0);
            self.set_final_appearance(e, slot);
            e.set_visible(slot, true);
        }
        self.settling.clear();
        e.active_clear();
        self.cleanup_done = true;
        self.hold_left = FINAL_HOLD_FRAMES - 1;
    }

    /// A generous bound on the frames the hooks can take; past it the text
    /// is forced into place (a guard, never reached in practice).
    fn frame_limit(&self, e: &Engine) -> u64 {
        let n = e.input_chars.len() as u64 + 1;
        let span = (e.canvas.width + e.canvas.height).max(1) as f64;
        let slowest = self.config.cast_speed.min(self.config.reel_speed).max(1e-9);
        let per_catch = (8.0 * span / slowest).min(1e12) as u64
            + 4 * self.config.cast_delay.max(0) as u64
            + 64;
        n.saturating_mul(per_catch).saturating_add(1000)
    }

    /// Cut the text into hauls: vertical runs within a column, top to
    /// bottom, at most MAX_HAUL long.
    fn build_hauls(e: &Engine, catchable: &[u32]) -> Vec<(Vec<u32>, i64, i64)> {
        let mut sorted = catchable.to_vec();
        sorted.sort_by_key(|&s| {
            let c = e.input_coord(s);
            (c.column, -c.row, e.ch.id[s as usize])
        });
        let mut runs: Vec<Vec<u32>> = Vec::new();
        for s in sorted {
            let c = e.input_coord(s);
            if let Some(run) = runs.last_mut() {
                let last = e.input_coord(*run.last().expect("run"));
                if last.column == c.column && last.row == c.row + 1 && run.len() < MAX_HAUL {
                    run.push(s);
                    continue;
                }
            }
            runs.push(vec![s]);
        }
        runs.into_iter()
            .map(|run| {
                let top = e.input_coord(run[0]);
                let order: Vec<u32> = run.into_iter().rev().collect();
                (order, top.column, top.row)
            })
            .collect()
    }
}

impl Effect for Fishing {
    fn build(&mut self, e: &mut Engine) -> Result<(), EngineError> {
        let config = self.config.clone();
        let canvas = e.canvas.clone();
        self.bang = e.sym("!");
        let water = if config.water_colors.is_empty() {
            vec![Color::from_rgb(0x10, 0x98, 0xAD)]
        } else {
            config.water_colors.clone()
        };
        self.junk_color = *water.last().expect("water colors");
        self.water = water.clone();
        let input = e.get_characters(CharacterFilter::default(), CharacterSort::TopToBottomLeftToRight);
        let space = e.sym(" ");
        let catchable: Vec<u32> = input.iter().copied().filter(|&s| e.input_sym(s) != space).collect();

        // final colors
        self.final_colors = vec![ColorPair::default(); e.char_count()];
        let dynamic = e.existing_color_handling() == ExistingColorHandling::Dynamic;
        if !input.is_empty() {
            let gradient = Gradient::new(&config.final_gradient_stops, &config.final_gradient_steps, false, false)
                .map_err(other)?;
            let mapping = if dynamic {
                None
            } else {
                Some(
                    gradient
                        .build_coordinate_color_mapping(
                            canvas.text_bottom,
                            canvas.text_top,
                            canvas.text_left,
                            canvas.text_right,
                            config.final_gradient_direction,
                        )
                        .map_err(other)?,
                )
            };
            for &slot in &input {
                self.final_colors[slot as usize] = match &mapping {
                    None => ColorPair::new(e.input_fg(slot), e.input_bg(slot)),
                    Some(m) => {
                        let fg = m
                            .get(&e.input_coord(slot))
                            .copied()
                            .or_else(|| gradient.spectrum.last().copied());
                        ColorPair::new(fg, None)
                    }
                };
            }
        }

        // the surface, when the text leaves the top row free
        let has_surface = canvas.top > canvas.text_top && canvas.height >= 2 && !catchable.is_empty();

        // hauls, and a school of fish for each: start cells outside the text
        // rows and below the surface while there is room
        let runs = Self::build_hauls(e, &catchable);
        let mut start = vec![Coord::new(0, 0); e.char_count()];
        if !catchable.is_empty() {
            let glyph_cells: std::collections::HashSet<Coord> =
                catchable.iter().map(|&s| e.input_coord(s)).collect();
            let text_rows = |c: Coord| c.row >= canvas.text_bottom && c.row <= canvas.text_top;
            let mut tiers: [Vec<Coord>; 4] = Default::default();
            for row in canvas.bottom..=canvas.top {
                for column in canvas.left..=canvas.right {
                    let c = Coord::new(column, row);
                    let tier = if glyph_cells.contains(&c) {
                        3
                    } else if row == canvas.top {
                        2
                    } else if text_rows(c) {
                        1
                    } else {
                        0
                    };
                    tiers[tier].push(c);
                }
            }
            let mut pool: Vec<Coord> = Vec::new();
            for tier in tiers.iter_mut() {
                if pool.len() >= catchable.len() {
                    break;
                }
                e.rng.shuffle(tier);
                pool.append(tier);
            }
            let mut order: Vec<usize> = (0..runs.len()).collect();
            e.rng.shuffle(&mut order);
            let mut schools = vec![Coord::new(0, 0); runs.len()];
            let mut ranked: Vec<(i64, usize)> = Vec::with_capacity(pool.len());
            for &r in &order {
                let fish = &runs[r].0;
                let center = pool[e.rng.choice_index(pool.len())];
                schools[r] = center;
                let take = fish.len().min(pool.len());
                ranked.clear();
                ranked.extend(pool.iter().enumerate().map(|(i, c)| {
                    let (dc, dr) = (c.column - center.column, c.row - center.row);
                    (dc * dc + 4 * dr * dr, i)
                }));
                if take < ranked.len() {
                    ranked.select_nth_unstable(take - 1);
                    ranked.truncate(take);
                }
                ranked.sort_unstable();
                let mut cells: Vec<Coord> = ranked.iter().map(|&(_, i)| pool[i]).collect();
                let mut taken: Vec<usize> = ranked.iter().map(|&(_, i)| i).collect();
                taken.sort_unstable_by(|a, b| b.cmp(a));
                for i in taken {
                    pool.swap_remove(i);
                }
                // never start on the glyph's own cell when it can be avoided
                for i in 0..cells.len() {
                    if cells[i] == e.input_coord(fish[i]) {
                        let j = (i + 1) % cells.len();
                        cells.swap(i, j);
                    }
                }
                for (i, &slot) in fish.iter().enumerate() {
                    let c = cells.get(i).copied().unwrap_or_else(|| e.input_coord(slot));
                    start[slot as usize] = c;
                    e.set_coordinate(slot, c);
                }
            }
            self.hauls = runs
                .into_iter()
                .zip(schools)
                .map(|((order, column, top_row), school)| Haul {
                    order,
                    column,
                    top_row,
                    school,
                })
                .collect();
        }

        // hooks and lines
        let wanted = match config.hook_count {
            0 => {
                let work: f64 = self
                    .hauls
                    .iter()
                    .map(|haul| {
                        let k = haul.order.len() as f64;
                        let dive = (canvas.top - haul.school.row) as f64;
                        let across = (haul.school.column - haul.column).abs() as f64;
                        let lower = (canvas.top - haul.top_row) as f64;
                        2.0 * dive + across + lower + 8.0 * k + 40.0
                    })
                    .sum();
                let most = (canvas.width / 6).max(3) as usize;
                ((work / AUTO_WORK).ceil() as usize).clamp(3, most)
            }
            n => n.max(0) as usize,
        };
        let hook_count = wanted
            .min(self.hauls.len())
            .min(canvas.width.max(0) as usize);
        let home_columns: Vec<i64> = match hook_count {
            0 => Vec::new(),
            1 => vec![canvas.center_column],
            n => {
                // spread with a half gap at each edge
                (0..n)
                    .map(|i| {
                        canvas.left
                            + round_half_even((i as f64 + 0.5) * canvas.width as f64 / n as f64 - 0.5)
                    })
                    .collect()
            }
        };
        let (cast, reel, transport, lower) =
            (e.name("cast"), e.name("reel"), e.name("transport"), e.name("lower"));
        let line_len = (canvas.height - 1).max(0) as usize;
        let (j, bar) = (e.sym("J"), e.sym("|"));
        let line_colors = ColorPair::new(Some(config.line_color), None);
        let n = home_columns.len() as i64;
        for (i, &column) in home_columns.iter().enumerate() {
            let at = Coord::new(column, canvas.top);
            let hook = e.add_character_sym(j, at);
            e.set_appearance(hook, Some(j), Some(line_colors));
            e.set_layer(hook, 12 + 3 * i as i32);
            e.set_visible(hook, true);
            let mut lines = Vec::with_capacity(line_len);
            for _ in 0..line_len {
                let line = e.add_character_sym(bar, at);
                e.set_appearance(line, Some(bar), Some(line_colors));
                e.set_layer(line, 10 + 3 * i as i32);
                lines.push(line);
            }
            let new_path = |e: &mut Engine, speed: f64, ease: Easing, name: Name| {
                e.path_new(hook, speed, Some(ease), None, 0, false, name).map_err(other)
            };
            let cast_path = new_path(e, config.cast_speed, Easing::InOutSine, cast)?;
            let reel_path = new_path(e, config.reel_speed, Easing::OutSine, reel)?;
            let transport_path = new_path(e, config.reel_speed, Easing::InOutSine, transport)?;
            let lower_path = new_path(e, config.reel_speed, Easing::InSine, lower)?;
            let wrong_pending = e.rng.random() < config.wrong_catch_chance;
            // the start ripples across the crew; a big crew still sets off
            // within about 16 cast delays
            let delay = i as i64 * config.cast_delay * 16 / n.max(16);
            self.hooks.push(Hook {
                hook,
                lines,
                line_shown: 0,
                line_coord: at,
                queue: Vec::new(),
                haul: None,
                next: 0,
                chain: Vec::new(),
                phase: Phase::Waiting,
                target: None,
                delay,
                bite_ticks: 0,
                bite_origin: None,
                release_ticks: 0,
                wrong_pending,
                junk: None,
                casting_junk: false,
                wrong_stage: WrongStage::None,
                wrong_ticks: 0,
                cast_path,
                reel_path,
                transport_path,
                lower_path,
            });
        }

        // shares: the hauls in column order, cut into even contiguous parts
        if !self.hooks.is_empty() {
            let n = self.hooks.len();
            let total = self.hauls.len();
            let (base, larger) = (total / n, total % n);
            let mut index = 0;
            for (i, hook) in self.hooks.iter_mut().enumerate() {
                let size = base + usize::from(i < larger);
                hook.queue.extend(index..index + size);
                index += size;
            }
        }

        // swimming: each school sways side to side together
        let swim_speed = (config.cast_speed * 0.2).min(0.25).max(0.05);
        let (swim_out, swim_back) = (e.name("swim_out"), e.name("swim_back"));
        for k in 0..self.hauls.len() {
            let color = water[e.rng.choice_index(water.len())];
            let side: i64 = if e.rng.random() < 0.5 { -1 } else { 1 };
            let fish = self.hauls[k].order.clone();
            for slot in fish {
                // a little shade variety inside the school
                let color = if e.rng.random() < 0.3 {
                    water[e.rng.choice_index(water.len())]
                } else {
                    color
                };
                let sym = e.input_sym(slot);
                e.set_appearance(slot, Some(sym), Some(ColorPair::new(Some(color), None)));
                e.set_layer(slot, 1);
                e.set_visible(slot, true);
                let origin = start[slot as usize];
                let to = [
                    Coord::new(origin.column + side, origin.row),
                    Coord::new(origin.column - side, origin.row),
                ]
                .into_iter()
                .find(|&c| in_canvas(e, c));
                let to = match to {
                    Some(c) => c,
                    None => {
                        let options = neighbors(e, origin);
                        if options.is_empty() {
                            continue;
                        }
                        options[e.rng.choice_index(options.len())]
                    }
                };
                let out = e
                    .path_new(slot, swim_speed, Some(Easing::InOutSine), None, SWIM_HOLD, false, swim_out)
                    .map_err(other)?;
                e.path_new_waypoint(out, to, None, Name::NONE).map_err(other)?;
                let back = e
                    .path_new(slot, swim_speed, Some(Easing::InOutSine), None, SWIM_HOLD, false, swim_back)
                    .map_err(other)?;
                e.path_new_waypoint(back, origin, None, Name::NONE).map_err(other)?;
                e.chain_paths(slot, &[swim_out, swim_back], true).map_err(other)?;
                e.activate_path(&mut NoHooks, slot, out);
                e.active_insert(slot);
            }
        }

        // ripples, one per hook
        let ripple = e.name("ripple");
        let (tilde, dash, dot) = (e.sym("~"), e.sym("-"), e.sym("."));
        self.wave_syms = [tilde, dash, dot];
        let bright = ColorPair::new(Some(*water.last().expect("water")), None);
        let deep = ColorPair::new(Some(water[0]), None);
        for _ in 0..self.hooks.len() {
            let slot = e.add_character_sym(tilde, Coord::new(canvas.left, canvas.bottom));
            e.set_layer(slot, RIPPLE_LAYER);
            let scene = e.scene_new(slot, ripple, false, None, None);
            e.add_frame(scene, tilde, 2, Some(bright), 0).map_err(other)?;
            e.add_frame(scene, dash, 2, Some(bright), 0).map_err(other)?;
            e.add_frame(scene, dot, 2, Some(deep), 0).map_err(other)?;
            self.ripples.push(slot);
            self.ripple_scene.push(scene);
            self.ripple_in_use.push(false);
        }

        // junk, one per hook when wrong catches can happen
        if config.wrong_catch_chance > 0.0 {
            let junk_symbols = [e.sym("?"), e.sym("#"), e.sym("*")];
            for _ in 0..self.hooks.len() {
                let sym = junk_symbols[e.rng.choice_index(junk_symbols.len())];
                let slot = e.add_character_sym(sym, Coord::new(canvas.left, canvas.bottom));
                e.set_layer(slot, 11);
                e.set_appearance(slot, Some(sym), Some(bright));
                self.junk_available.push(slot);
            }
            self.junk_available.reverse();
        }

        // the surface
        if has_surface {
            for column in canvas.left..=canvas.right {
                let slot = e.add_character_sym(tilde, Coord::new(column, canvas.top));
                e.set_layer(slot, 0);
                e.set_visible(slot, true);
                self.surface.push(slot);
            }
            self.step_surface(e);
        }

        // post-logo signature flourish (lake waterline, floating bobber, jumping fish)
        self.flourish = Flourish::build(e, config.line_color, !catchable.is_empty());
        Ok(())
    }

    fn next_frame(&mut self, e: &mut Engine) -> bool {
        if self.cleanup_done {
            if self.hold_left > 0 {
                self.hold_left -= 1;
                return true;
            }
            return false;
        }
        self.frames += 1;

        for h in 0..self.hooks.len() {
            let phase = self.hooks[h].phase;
            let idle = Self::idle(e, self.hooks[h].hook);
            match phase {
                Phase::Casting if idle => {
                    if self.hooks[h].casting_junk {
                        self.start_wrong_catch(e, h);
                    } else {
                        let hook = &mut self.hooks[h];
                        hook.phase = Phase::Biting;
                        hook.bite_ticks = BITE_FRAMES;
                        let origin = hook.target.map(|t| e.coord(t));
                        hook.bite_origin = origin;
                        if let Some(origin) = origin {
                            self.emit_ripple(e, origin);
                        }
                    }
                }
                Phase::Biting => {
                    let hook = &mut self.hooks[h];
                    if hook.bite_ticks != 0 {
                        Self::wiggle_target(e, hook);
                    } else {
                        self.hook_fish(e, h);
                    }
                }
                Phase::Reeling if idle => self.start_transporting(e, h),
                Phase::Transporting if idle => self.start_lowering(e, h),
                Phase::Lowering if idle => self.start_releasing(e, h),
                Phase::Releasing => {
                    let cast_delay = self.config.cast_delay;
                    let hook = &mut self.hooks[h];
                    if hook.release_ticks != 0 {
                        hook.release_ticks -= 1;
                    } else {
                        hook.haul = None;
                        hook.next = 0;
                        hook.delay = cast_delay;
                        hook.phase = Phase::Waiting;
                    }
                }
                Phase::WrongCatch => self.advance_wrong_catch(e, h),
                Phase::Returning if idle => {
                    let cast_delay = self.config.cast_delay;
                    let hook = &mut self.hooks[h];
                    hook.delay = cast_delay;
                    hook.phase = Phase::Waiting;
                }
                Phase::Leaving if idle => Self::finish(e, &mut self.hooks[h]),
                Phase::Waiting => {
                    let hook = &mut self.hooks[h];
                    if hook.delay != 0 {
                        hook.delay -= 1;
                    } else {
                        self.start_cast(e, h);
                    }
                }
                _ => {}
            }
        }

        e.update(&mut NoHooks);
        // ripple_pool.reclaim_on_event(SCENE_COMPLETE): a finished scene
        // leaves the character without one
        for i in 0..self.ripples.len() {
            let slot = self.ripples[i];
            if self.ripple_in_use[i] && e.ch.scene[slot as usize] == NONE {
                self.ripple_in_use[i] = false;
                e.set_visible(slot, false);
                e.active_remove(slot);
            }
        }
        for hook in &mut self.hooks {
            Self::sync_chain(e, hook);
            Self::sync_line(e, hook);
        }
        self.step_settling(e);
        let all_done = self.hooks.iter().all(|h| h.phase == Phase::Finished);
        if all_done && !self.surface.is_empty() {
            self.calm = Some(self.calm.map_or(0, |c| c + 1));
        }
        self.step_surface(e);
        if all_done && self.settling.is_empty() && self.flourish.enabled && !self.flourish.is_done() {
            self.flourish.step(e, &self.water, self.config.line_color);
        }
        let calmed = self.surface.is_empty() || self.calm.is_some_and(|c| c > CALM_FRAMES + 6);
        let flourish_done = self.flourish.is_done();
        if (all_done && calmed && self.settling.is_empty() && flourish_done)
            || self.frames > self.frame_limit(e)
        {
            self.cleanup(e);
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::ctx::Clock;
    use crate::engine::terminal::TerminalConfig;
    use crate::fx::CF_ADDED;
    use crate::utils::rng::Rng;
    use clap::Parser;

    #[derive(Parser)]
    struct Cli {
        #[command(flatten)]
        config: FishingConfig,
    }

    fn config(args: &[&str]) -> FishingConfig {
        let mut argv = vec!["fishing"];
        argv.extend_from_slice(args);
        Cli::parse_from(argv).config
    }

    fn engine(input: &str, width: i64, height: i64, handling: ExistingColorHandling, seed: u64) -> Engine {
        let terminal = TerminalConfig {
            canvas_width: width,
            canvas_height: height,
            ignore_terminal_dimensions: true,
            existing_color_handling: handling,
            ..TerminalConfig::default()
        };
        Engine::new(input, terminal, Rng::seeded(seed), Clock::virtual_with_frame_rate(60)).unwrap()
    }

    /// Run to completion (bounded); returns the frame count and the engine.
    fn run(input: &str, width: i64, height: i64, args: &[&str], handling: ExistingColorHandling) -> (u64, Engine) {
        let mut e = engine(input, width, height, handling, 7);
        let mut effect = Fishing::new(config(args));
        effect.build(&mut e).unwrap();
        let mut frames = 0u64;
        while effect.next_frame(&mut e) {
            frames += 1;
            assert!(frames < 200_000, "fishing did not finish");
        }
        (frames, e)
    }

    fn assert_final(e: &Engine, handling: ExistingColorHandling) {
        for &slot in &e.input_chars {
            assert!(e.is_visible(slot), "input character hidden");
            assert_eq!(e.coord(slot), e.input_coord(slot));
            let info = e.visual_info(e.current_visual(slot));
            assert_eq!(info.sym, e.input_sym(slot));
            if handling == ExistingColorHandling::Dynamic {
                assert_eq!(info.fg, e.input_fg(slot));
                assert_eq!(info.bg, e.input_bg(slot));
            }
        }
        for &slot in &e.added_chars {
            assert!(e.ch.flags[slot as usize] & CF_ADDED != 0);
            assert!(!e.is_visible(slot), "auxiliary character left visible");
        }
    }

    #[test]
    fn runs_to_completion_on_edge_inputs() {
        let ignore = ExistingColorHandling::Ignore;
        let long = "x".repeat(500);
        let cases: Vec<(&str, i64, i64)> = vec![
            ("OMARCHY\nhello world\n", 40, 12),
            ("", 20, 5),
            ("   ", 20, 5),
            ("a", 1, 1),
            ("a", 20, 5),
            ("OMARCHY\nhello world", 10, 3),
            (&long, 80, 10),
            ("日本語のテキスト\nwide ✓ chars", 30, 8),
            ("\x1b[31mred\x1b[0m \x1b[44mblue bg\x1b[0m", 30, 6),
            ("big canvas", 300, 120),
        ];
        for (input, w, h) in cases {
            if input.trim().is_empty() {
                // the engine rejects blank input (the CLI substitutes "NO INPUT.")
                let terminal = TerminalConfig {
                    canvas_width: w,
                    canvas_height: h,
                    ignore_terminal_dimensions: true,
                    ..TerminalConfig::default()
                };
                if Engine::new(input, terminal, Rng::seeded(1), Clock::virtual_with_frame_rate(60)).is_err() {
                    continue;
                }
            }
            let (_, e) = run(input, w, h, &[], ignore);
            assert_final(&e, ignore);
            let (_, e) = run(input, w, h, &["--wrong-catch-chance", "1", "--hook-count", "5"], ignore);
            assert_final(&e, ignore);
        }
    }

    #[test]
    fn dynamic_restores_input_colors() {
        let dynamic = ExistingColorHandling::Dynamic;
        let (_, e) = run("\x1b[31mred\x1b[0m plain \x1b[1;32mgreen\x1b[0m", 30, 6, &[], dynamic);
        assert_final(&e, dynamic);
        let (_, e) = run("\x1b[31mred\x1b[0m", 30, 6, &[], ExistingColorHandling::Always);
        assert_final(&e, ExistingColorHandling::Always);
    }

    #[test]
    fn deterministic_for_a_seed() {
        let ignore = ExistingColorHandling::Ignore;
        let trace = || {
            let mut e = engine("OMARCHY\nhello world", 40, 10, ignore, 3);
            let mut effect = Fishing::new(config(&["--wrong-catch-chance", "0.5"]));
            effect.build(&mut e).unwrap();
            let mut coords = Vec::new();
            while effect.next_frame(&mut e) {
                coords.push(e.ch.coord.clone());
            }
            coords
        };
        assert_eq!(trace(), trace());
    }

    #[test]
    fn timing_options_change_the_length() {
        let ignore = ExistingColorHandling::Ignore;
        let input = "OMARCHY\nhello world";
        let base = run(input, 40, 10, &["--wrong-catch-chance", "0"], ignore).0;
        for args in [
            &["--wrong-catch-chance", "0", "--cast-speed", "0.3"][..],
            &["--wrong-catch-chance", "0", "--reel-speed", "0.5"][..],
            &["--wrong-catch-chance", "0", "--cast-delay", "20"][..],
            &["--wrong-catch-chance", "1"][..],
            &["--wrong-catch-chance", "0", "--hook-count", "1"][..],
        ] {
            let frames = run(input, 40, 10, args, ignore).0;
            assert_ne!(frames, base, "{args:?} did not change the run length");
        }
    }
    /// The stock Omarchy logo (the screensaver's default text).
    const LOGO: &str = r"                 ▄▄▄
 ▄█████▄    ▄███████████▄    ▄███████   ▄███████   ▄███████   ▄█   █▄    ▄█   █▄
███   ███  ███   ███   ███  ███   ███  ███   ███  ███   ███  ███   ███  ███   ███
███   ███  ███   ███   ███  ███   ███  ███   ███  ███   █▀   ███   ███  ███   ███
███   ███  ███   ███   ███ ▄███▄▄▄███ ▄███▄▄▄██▀  ███       ▄███▄▄▄███▄ ███▄▄▄███
███   ███  ███   ███   ███ ▀███▀▀▀███ ▀███▀▀▀▀    ███      ▀▀███▀▀▀███  ▀▀▀▀▀▀███
███   ███  ███   ███   ███  ███   ███ ██████████  ███   █▄   ███   ███  ▄██   ███
███   ███  ███   ███   ███  ███   ███  ███   ███  ███   ███  ███   ███  ███   ███
 ▀█████▀    ▀█   ███   █▀   ███   █▀   ███   ███  ███████▀   ███   █▀    ▀█████▀
                                       ███   █▀";

    #[test]
    fn logo_runs_screensaver_length_on_any_screen() {
        let ignore = ExistingColorHandling::Ignore;
        let text = LOGO;
        for (w, h) in [(96, 24), (160, 42), (300, 90)] {
            let started = std::time::Instant::now();
            let (frames, e) = run(text, w, h, &[], ignore);
            assert_final(&e, ignore);
            assert!((960..=3000).contains(&frames), "{w}x{h}: {frames} frames");
            assert!(started.elapsed().as_secs_f64() < 2.0, "{w}x{h} too slow");
        }
    }

    #[test]
    fn a_run_lands_all_at_once() {
        let ignore = ExistingColorHandling::Ignore;
        let mut e = engine("ab\ncd\nef", 40, 12, ignore, 5);
        let mut effect = Fishing::new(config(&["--wrong-catch-chance", "0", "--hook-count", "1"]));
        effect.build(&mut e).unwrap();
        let slots = e.input_chars.clone();
        let mut landed = vec![None; slots.len()];
        let mut frame = 0;
        while effect.next_frame(&mut e) && !effect.cleanup_done {
            frame += 1;
            for (i, &s) in slots.iter().enumerate() {
                if landed[i].is_none() && e.layer(s) == LANDED_LAYER {
                    landed[i] = Some(frame);
                }
            }
        }
        let at = |sym: &str| {
            let i = slots.iter().position(|&s| e.symbol(e.input_sym(s)) == sym).unwrap();
            landed[i].expect("landed before cleanup")
        };
        // two columns, each one string of three
        assert_eq!(at("a"), at("c"));
        assert_eq!(at("a"), at("e"));
        assert_eq!(at("b"), at("d"));
        assert_eq!(at("b"), at("f"));
        assert_ne!(at("a"), at("b"));
    }
}
