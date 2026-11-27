//! sunshower: rain falls from a grey cloud bank onto the dimmed text, the
//! sun climbs up behind the clouds and lights them, a rainbow is drawn
//! across the sky from one foot to the other, and its light sweeps over the
//! text, leaving it glowing in the same spectrum. Then the rain eases off,
//! the clouds blow away, and the rainbow dissolves, leaving the sun to sweep
//! slow golden lighthouse rays behind the finished logo while a few last
//! raindrops glint gold as they fall past, before the sky clears completely.
//!
//! Original effect by Lukas Innig (@derluke), https://github.com/derluke/ttfx, MIT.
//!
//! Rewritten for the fx engine. Everything is driven directly each frame
//! (coordinates, visibility, visuals) from a frame counter, as the original
//! did; no scenes or paths. Every visual (including every fade step) is made
//! at build time, so a frame only moves handles around.
//!
//! Composition, sized from the canvas so it fills a fullscreen screensaver:
//! - the rainbow is a full arc standing on the bottom edge and spanning the
//!   sky around the text, revealed along its length (foot to foot);
//! - the text lights up as the arc's leading edge sweeps past its angle, in
//!   bands concentric with the arc (outermost color at the top corners);
//! - rain is two depths: far drops fall behind the text, near drops land on
//!   the tops of the letters and splash (the letter glints where hit);
//! - the cloud bank, rain, splashes, lighthouse rays, and golden raindrops
//!   scale with the canvas, the sun and the clouds with its height.
//!
//! Timeline: the weather clears once both the rainbow and the sunrise are
//! complete and `--hold-time` has passed, followed by the golden sunbreak
//! flourish over `--final-hold-time`, so every timing option feeds the
//! run length. Timings are in frames; the defaults suit 120 fps.
//!
//! Layers: text spaces -2 (so the sky shows through gaps between letters),
//! rain -1 (behind the rainbow and the sun), rainbow 1, sun 2, lighthouse
//! rays 3, clouds & far golden drops 4, text 5, splashes & near golden
//! drops 6.

use clap::Args;

use crate::cli::parse_color;
use crate::effects::common::{
    parse_non_negative_float, parse_non_negative_int, parse_positive_float_range,
    parse_positive_int, parse_symbol,
};
use crate::engine::animation::ExistingColorHandling;
use crate::engine::error::EngineError;
use crate::engine::terminal::{CharacterFilter, CharacterSort};
use crate::fx::run::Effect;
use crate::fx::visual::{VisualInfo, BOLD, HAS_COLORS};
use crate::fx::{Engine, Hooks, Sym, Visual};
use crate::utils::geometry::Coord;
use crate::utils::graphics::Color;

#[derive(Args, Debug, Clone)]
pub struct SunshowerConfig {
    /// Number of raindrops per 96x24 screenful; scales with the canvas area.
    #[arg(long = "rain-density", default_value_t = 170, value_parser = parse_positive_int)]
    pub rain_density: i64,

    /// Falling speed range of the raindrops in cells per frame.
    #[arg(long = "rain-speed", default_value = "0.3-0.7", value_parser = parse_positive_float_range)]
    pub rain_speed: (f64, f64),

    /// Columns the rain drifts left per row fallen.
    #[arg(long = "rain-wind", default_value_t = 0.3, value_parser = parse_non_negative_float)]
    pub rain_wind: f64,

    /// Space separated list of symbols used for raindrops.
    #[arg(long = "rain-symbols", num_args = 1.., value_parser = parse_symbol,
          default_values = ["/", "/", "/", "'", ","])]
    pub rain_symbols: Vec<String>,

    /// Space separated list of colors used for raindrops.
    #[arg(long = "rain-colors", num_args = 1.., value_parser = parse_color,
          default_values = ["3977a8", "55a6d9", "8bd3f7", "d4f1ff"])]
    pub rain_colors: Vec<Color>,

    /// Frame on which the sun begins to rise.
    #[arg(long = "sun-start", default_value_t = 150, value_parser = parse_non_negative_int)]
    pub sun_start: i64,

    /// Number of frames the sunrise takes.
    #[arg(long = "sunrise-duration", default_value_t = 260, value_parser = parse_positive_int)]
    pub sunrise_duration: i64,

    /// Color of the sun and its rays.
    #[arg(long = "sun-color", default_value = "ffd447", value_parser = parse_color)]
    pub sun_color: Color,

    /// Frame on which the rainbow begins to grow.
    #[arg(long = "rainbow-start", default_value_t = 330, value_parser = parse_non_negative_int)]
    pub rainbow_start: i64,

    /// Number of frames the rainbow takes to cross the sky.
    #[arg(long = "rainbow-duration", default_value_t = 300, value_parser = parse_positive_int)]
    pub rainbow_duration: i64,

    /// Space separated colors for the rainbow, ordered outermost to innermost.
    #[arg(long = "rainbow-colors", num_args = 1.., value_parser = parse_color,
          default_values = ["ff3b30", "ff9500", "ffd60a", "34c759", "00b7ff", "5856d6", "af52de"])]
    pub rainbow_colors: Vec<Color>,

    /// Frames to hold the completed sunshower before the weather clears.
    #[arg(long = "hold-time", default_value_t = 260, value_parser = parse_non_negative_int)]
    pub hold_time: i64,

    /// Frames used to clear the rain, clouds, sun, and rainbow from the canvas.
    #[arg(long = "clear-duration", default_value_t = 220, value_parser = parse_positive_int)]
    pub clear_duration: i64,

    /// Frames to admire the rainbow-colored text after the sky clears.
    #[arg(long = "final-hold-time", default_value_t = 380, value_parser = parse_non_negative_int)]
    pub final_hold_time: i64,
}

const LAYER_SPACE: i32 = -2;
const LAYER_RAIN: i32 = -1;
const LAYER_RAINBOW: i32 = 1;
const LAYER_SUN: i32 = 2;
const LAYER_RAY: i32 = 3;
const LAYER_CLOUD: i32 = 4;
const LAYER_TEXT: i32 = 5;
const LAYER_SPLASH: i32 = 6;

/// Fade steps (index FADE = gone).
const FADE: usize = 10;
/// Cloud brightness steps (rain-dark .. sunlit).
const LIGHT: usize = 8;
/// Text light-up ramp: white flash easing into the final color.
const RAMP: usize = 8;
const RAMP_FRAMES: i64 = 3;
/// Frames a letter glints where a raindrop hits it.
const GLINT_FRAMES: i64 = 7;
/// Splash: "." then "v" then "·".
const SPLASH_STAGES: [(&str, i64); 3] = [(".", 3), ("v", 5), ("·", 4)];
/// Ray directions around the sun.
const RAYS: usize = 16;
/// Lighthouse sunbeam brightness levels (1..=RAY_LEVELS; 0 = hidden).
const RAY_LEVELS: usize = 5;
/// Number of evenly spaced lighthouse beams rotating around the sun.
const NUM_BEAMS: f64 = 6.0;
/// Angular half-width (radians) of each lighthouse beam.
const BEAM_HALF_WIDTH: f64 = 0.115;
/// Reference screen the density option is given for.
const REF_AREA: f64 = 96.0 * 24.0;

const DIM_TEXT: &str = "526675";
const SKY: &str = "12121a";
const WHITE: &str = "ffffff";
/// Cloud shades (lit top, shadowed body) in the rain and in the sun.
const CLOUD_RAIN: [&str; 2] = ["6f7f8c", "4a5865"];
const CLOUD_SUN: [&str; 2] = ["e4edf3", "a9bdca"];

struct RainDrop {
    slot: u32,
    col: f64,
    row: f64,
    speed: f64,
    /// Near drops land on the letters; far drops fall behind them.
    near: bool,
    /// When the drop retires while the sky clears (0..1).
    fallaway: f64,
    alive: bool,
    color: Visual,
    sunlit: Visual,
}

struct Splash {
    slot: u32,
    born: i64,
}

struct CloudPart {
    slot: u32,
    offset: Coord,
    /// index into `cloud_visuals`: (symbol * 2 + shade)
    kind: usize,
}

struct Cloud {
    parts: Vec<CloudPart>,
    col: f64,
    row: i64,
    speed: f64,
    width: i64,
}

struct SunPart {
    slot: u32,
    offset: Coord,
    /// None for the disc, Some((ray, step)) for a ray cell.
    ray: Option<(usize, usize)>,
    /// index into `sun_visuals`
    kind: usize,
}

struct RainbowCell {
    slot: u32,
    reveal: f64,
    jitter: f64,
    band: usize,
    /// 0 hidden, 1 fresh, 2.. fade step + 2
    state: u8,
}

struct TextChar {
    slot: u32,
    reveal: f64,
    sun_angle: f64,
    dim: Visual,
    glint_dim: Visual,
    ramp: [Visual; RAMP],
    glint_lit: Visual,
    /// Gentle warm golden highlight levels when a lighthouse beam sweeps behind.
    sun_kissed: [Visual; 2],
    lit_at: i64,
    glint_until: i64,
    flourish_level: u8,
    dirty: bool,
}

struct RayCell {
    slot: u32,
    angle: f64,
    /// Precomputed radial & soft-edge attenuation in 0..=1.
    weight: f64,
    /// 0 = hidden, 1..=RAY_LEVELS = brightness level.
    state: u8,
}

struct GoldenDrop {
    slot: u32,
    col: f64,
    row: f64,
    speed: f64,
    near: bool,
    start_frame: i64,
    alive: bool,
    /// [soft gold, bright sunlit gold, white-gold beam glint]
    visuals: [Visual; 3],
    vis_state: u8,
}

pub struct Sunshower {
    config: SunshowerConfig,
    rain: Vec<RainDrop>,
    splashes: Vec<Splash>,
    next_splash: usize,
    splash_visuals: [Visual; 3],
    gold_splash_visuals: [Visual; 3],
    clouds: Vec<Cloud>,
    /// [kind][light][fade]
    cloud_visuals: Vec<[[Visual; FADE]; LIGHT]>,
    sun: Vec<SunPart>,
    /// [kind][fade]
    sun_visuals: Vec<[Visual; FADE]>,
    sun_target: Coord,
    ray_len: usize,
    sun_start_row: i64,
    rainbow: Vec<RainbowCell>,
    /// [band][fresh, fade 0.., ]
    rainbow_visuals: Vec<[Visual; FADE + 1]>,
    text: Vec<TextChar>,
    /// Text index at a canvas cell, for the near rain to land on.
    solid: Vec<u32>,
    /// Text indices in reveal order; `[..lit]` are lit.
    order: Vec<u32>,
    lit: usize,
    dirty: Vec<u32>,
    solid_text: Vec<u32>,
    ray_cells: Vec<RayCell>,
    ray_visuals: [Visual; RAY_LEVELS],
    golden_drops: Vec<GoldenDrop>,
    gold_spawn_left: f64,
    gold_spawn_right: f64,
    frame: i64,
    sunrise_end: i64,
    rainbow_end: i64,
    clear_start: i64,
    clear_end: i64,
    ray_start: i64,
    end_frame: i64,
}

impl Sunshower {
    pub fn new(config: SunshowerConfig) -> Self {
        Sunshower {
            config,
            rain: Vec::new(),
            splashes: Vec::new(),
            next_splash: 0,
            splash_visuals: [Visual(crate::fx::NONE); 3],
            gold_splash_visuals: [Visual(crate::fx::NONE); 3],
            clouds: Vec::new(),
            cloud_visuals: Vec::new(),
            sun: Vec::new(),
            sun_visuals: Vec::new(),
            sun_target: Coord::new(0, 0),
            ray_len: 1,
            sun_start_row: 0,
            rainbow: Vec::new(),
            rainbow_visuals: Vec::new(),
            text: Vec::new(),
            solid: Vec::new(),
            order: Vec::new(),
            lit: 0,
            dirty: Vec::new(),
            solid_text: Vec::new(),
            ray_cells: Vec::new(),
            ray_visuals: [Visual(crate::fx::NONE); RAY_LEVELS],
            golden_drops: Vec::new(),
            gold_spawn_left: 0.0,
            gold_spawn_right: 0.0,
            frame: 0,
            sunrise_end: 0,
            rainbow_end: 0,
            clear_start: 0,
            clear_end: 0,
            ray_start: 0,
            end_frame: 0,
        }
    }

    fn clear_progress(&self) -> f64 {
        if self.frame < self.clear_start {
            0.0
        } else {
            ((self.frame - self.clear_start) as f64 / self.config.clear_duration as f64)
                .clamp(0.0, 1.0)
        }
    }

    fn sunrise_progress(&self) -> f64 {
        let p = (self.frame - self.config.sun_start) as f64 / self.config.sunrise_duration as f64;
        let p = p.clamp(0.0, 1.0);
        1.0 - (1.0 - p).powi(3)
    }

    fn solid_at(&self, e: &Engine, col: i64, row: i64) -> Option<u32> {
        let c = &e.canvas;
        if col < c.left || col > c.right || row < c.bottom || row > c.top {
            return None;
        }
        let i = ((row - c.bottom) * c.width + (col - c.left)) as usize;
        match self.solid.get(i) {
            Some(&t) if t != u32::MAX => Some(t),
            _ => None,
        }
    }

    fn splash(&mut self, e: &mut Engine, col: i64, row: i64) {
        if self.splashes.is_empty() {
            return;
        }
        let n = self.splashes.len();
        let s = &mut self.splashes[self.next_splash];
        self.next_splash = (self.next_splash + 1) % n;
        s.born = self.frame;
        e.set_coordinate(s.slot, Coord::new(col, row));
    }

    fn glint(&mut self, t: u32) {
        let frame = self.frame;
        let c = &mut self.text[t as usize];
        c.glint_until = frame + GLINT_FRAMES;
        if !c.dirty {
            c.dirty = true;
            self.dirty.push(t);
        }
    }

    fn update_rain(&mut self, e: &mut Engine) {
        let (bottom, top) = (e.canvas.bottom, e.canvas.top);
        let (left, right) = (e.canvas.left as f64, e.canvas.right as f64);
        let wind = self.config.rain_wind;
        let span = right + wind * (top - bottom + 1) as f64 + 1.0;
        let clear = self.clear_progress();
        let sunny = self.sunrise_progress();
        let (slow, fast) = self.config.rain_speed;
        for i in 0..self.rain.len() {
            if !self.rain[i].alive {
                continue;
            }
            let (col, row, speed, near, fallaway) = {
                let d = &self.rain[i];
                (d.col, d.row, d.speed, d.near, d.fallaway)
            };
            // stragglers still falling late in the clear vanish
            if fallaway < clear * 1.4 - 0.5 || self.frame >= self.clear_end {
                self.rain[i].alive = false;
                e.set_visible(self.rain[i].slot, false);
                continue;
            }
            let new_row = row - speed;
            let new_col = col - speed * wind;
            let mut landed = None;
            if near {
                let (r0, r1) = (row.round() as i64, new_row.round() as i64);
                let mut r = r0 - 1;
                while r >= r1.max(bottom - 1) {
                    let c = (col - (row - r as f64) * wind).round() as i64;
                    if let Some(t) = self.solid_at(e, c, r) {
                        landed = Some((c, r, Some(t)));
                        break;
                    }
                    r -= 1;
                }
            }
            if landed.is_none() && new_row.round() < bottom as f64 {
                landed = Some((new_col.round() as i64, bottom - 1, None));
            }
            if let Some((c, r, hit)) = landed {
                // splash on the surface it hit
                if self.frame < self.clear_end && self.solid_at(e, c, r + 1).is_none() {
                    self.splash(e, c, r + 1);
                }
                if let Some(t) = hit {
                    self.glint(t);
                }
                let d = &mut self.rain[i];
                if fallaway < clear * 1.25 {
                    d.alive = false;
                    e.set_visible(d.slot, false);
                    continue;
                }
                d.col = e.rng.uniform(left, span);
                d.row = top as f64 + e.rng.uniform(0.0, 3.0);
                d.speed = e.rng.uniform(slow, fast) * if d.near { 1.0 } else { 0.7 };
                let lit = sunny > 0.5 && e.rng.random() < 0.3 * sunny;
                e.set_visual(d.slot, if lit { d.sunlit } else { d.color });
            } else {
                let d = &mut self.rain[i];
                d.row = new_row;
                d.col = new_col;
            }
            let d = &self.rain[i];
            e.set_coordinate(d.slot, Coord::new(d.col.round() as i64, d.row.round() as i64));
            e.set_visible(d.slot, true);
        }
    }

    fn update_splashes(&mut self, e: &mut Engine) {
        let total: i64 = SPLASH_STAGES.iter().map(|s| s.1).sum();
        let gold = self.frame >= self.clear_end && self.config.final_hold_time > 0;
        let visuals = if gold { &self.gold_splash_visuals } else { &self.splash_visuals };
        for s in &self.splashes {
            let age = self.frame - s.born;
            let active = s.born >= 0 && age < total && self.frame < self.end_frame;
            if active {
                let mut stage = 0;
                let mut acc = 0;
                for (k, (_, len)) in SPLASH_STAGES.iter().enumerate() {
                    acc += len;
                    if age < acc {
                        stage = k;
                        break;
                    }
                }
                e.set_visual(s.slot, visuals[stage]);
            }
            e.set_visible(s.slot, active);
        }
    }

    fn update_clouds(&mut self, e: &mut Engine) {
        let clear = self.clear_progress();
        let light = ((self.sunrise_progress() * (LIGHT - 1) as f64).round() as usize).min(LIGHT - 1);
        let fade = ((clear * FADE as f64) as usize).min(FADE);
        let (left, right) = (e.canvas.left as f64, e.canvas.right as f64);
        for cloud in &mut self.clouds {
            // the wind picks up and blows the clouds away as the sky clears
            cloud.col -= cloud.speed * (1.0 + 10.0 * clear * clear);
            if clear == 0.0 && cloud.col + (cloud.width as f64) < left - 1.0 {
                cloud.col = right + 1.0;
            }
            let col = cloud.col.round() as i64;
            for part in &cloud.parts {
                e.set_coordinate(part.slot, Coord::new(col + part.offset.column, cloud.row + part.offset.row));
                if fade < FADE {
                    e.set_visual(part.slot, self.cloud_visuals[part.kind][light][fade]);
                }
                e.set_visible(part.slot, fade < FADE);
            }
        }
    }

    fn update_sun(&mut self, e: &mut Engine) {
        if self.frame < self.config.sun_start {
            return;
        }
        let rise = self.sunrise_progress();
        let clear = self.clear_progress();
        let row = self.sun_start_row as f64 + (self.sun_target.row - self.sun_start_row) as f64 * rise;
        let center = Coord::new(self.sun_target.column, row.round() as i64);
        // rays grow as it rises, pulse, and retract as the sky clears
        let reach = rise * (1.0 - (clear * 2.0).min(1.0));
        let pulse = (self.frame / 14) % 2;
        let fade = if self.config.final_hold_time > 0 {
            if self.frame < self.clear_end {
                // soften slightly as the sky clears, staying as the lighthouse source
                (((clear - 0.3) / 0.7).max(0.0) * 2.0).round() as usize
            } else {
                let p = ((self.frame - self.clear_end) as f64 / self.config.final_hold_time as f64)
                    .clamp(0.0, 1.0);
                if p < 0.65 {
                    // gentle warm breathing while the lighthouse beams sweep
                    if (self.frame / 28) % 2 == 0 { 1 } else { 2 }
                } else {
                    let t = ((p - 0.65) / 0.25).clamp(0.0, 1.0);
                    (2.0 + t * (FADE - 2) as f64).round() as usize
                }
            }
        } else {
            (((clear - 0.3) / 0.7).max(0.0) * FADE as f64) as usize
        };
        for part in &self.sun {
            let mut visible = fade < FADE;
            if let Some((ray, step)) = part.ray {
                let len = self.ray_len;
                let shown = (len as f64 * reach).round() as usize;
                let shown = if ray % 2 == 0 { shown.saturating_sub(pulse as usize) } else { shown.min(len - 1) };
                let flicker = ray % 2 == 0 || (ray / 2 + pulse as usize) % 2 == 0;
                visible &= step < shown && flicker;
            }
            if visible {
                e.set_visual(part.slot, self.sun_visuals[part.kind][fade]);
                e.set_coordinate(part.slot, Coord::new(center.column + part.offset.column, center.row + part.offset.row));
            }
            e.set_visible(part.slot, visible);
        }
    }

    fn update_rainbow(&mut self, e: &mut Engine) {
        if self.frame < self.config.rainbow_start {
            return;
        }
        let progress = ((self.frame - self.config.rainbow_start) as f64
            / self.config.rainbow_duration as f64)
            .clamp(0.0, 1.0);
        let clear = self.clear_progress();
        let settled = self.frame > self.rainbow_end + 1 && self.frame < self.clear_start;
        if !settled {
            for cell in &mut self.rainbow {
                let state = if cell.reveal > progress {
                    0
                } else if clear > 0.0 {
                    let f = ((clear * 1.4 - cell.jitter * 0.4).clamp(0.0, 1.0) * FADE as f64) as usize;
                    if f >= FADE { 0 } else { f as u8 + 2 }
                } else if progress < 1.0 && progress - cell.reveal < 0.035 {
                    1
                } else {
                    2
                };
                if state != cell.state {
                    cell.state = state;
                    if state > 0 {
                        e.set_visual(cell.slot, self.rainbow_visuals[cell.band][state as usize - 1]);
                    }
                    e.set_visible(cell.slot, state > 0);
                }
            }
        }
        // the light sweeps over the text with the arc's leading edge
        while self.lit < self.order.len() && self.text[self.order[self.lit] as usize].reveal <= progress {
            let t = self.order[self.lit];
            self.lit += 1;
            let c = &mut self.text[t as usize];
            c.lit_at = self.frame;
            if !c.dirty {
                c.dirty = true;
                self.dirty.push(t);
            }
        }
    }

    fn update_text(&mut self, e: &mut Engine) {
        let frame = self.frame;
        let text = &mut self.text;
        self.dirty.retain(|&t| {
            let c = &mut text[t as usize];
            let lit = c.lit_at <= frame;
            let glinting = frame < c.glint_until;
            let step = if lit { ((frame - c.lit_at) / RAMP_FRAMES) as usize } else { 0 };
            let visual = match (lit, glinting) {
                (false, false) => c.dim,
                (false, true) => c.glint_dim,
                (true, true) if step >= RAMP - 1 => c.glint_lit,
                (true, _) if step >= RAMP - 1 => match c.flourish_level {
                    2 => c.sun_kissed[1],
                    1 => c.sun_kissed[0],
                    _ => c.ramp[RAMP - 1],
                },
                (true, _) => c.ramp[step.min(RAMP - 1)],
            };
            e.set_visual(c.slot, visual);
            let done = !glinting && (!lit || step >= RAMP - 1);
            if done {
                c.dirty = false;
            }
            !done
        });
    }

    /// Returns `(envelope, beam_phase, flourish_progress)` for the lighthouse flourish.
    fn flourish_params(&self) -> (f64, f64, f64) {
        if self.config.final_hold_time <= 0 || self.frame < self.ray_start || self.frame >= self.end_frame {
            return (0.0, 0.0, 0.0);
        }
        let fade_in_span = (self.clear_end - self.ray_start).max(1) as f64;
        let t_in = ((self.frame - self.ray_start) as f64 / fade_in_span).clamp(0.0, 1.0);
        let ease_in = t_in * t_in * (3.0 - 2.0 * t_in);

        let p = if self.frame < self.clear_end {
            0.0
        } else {
            ((self.frame - self.clear_end) as f64 / self.config.final_hold_time as f64).clamp(0.0, 1.0)
        };
        let t_out = ((0.90 - p) / 0.25).clamp(0.0, 1.0);
        let ease_out = t_out * t_out * (3.0 - 2.0 * t_out);

        let total_span = (self.end_frame - self.ray_start).max(1) as f64;
        let u_sweep = ((self.frame - self.ray_start) as f64 / total_span).clamp(0.0, 1.0);
        let spacing = std::f64::consts::TAU / NUM_BEAMS;
        // sweeps slowly left-to-right across the logo like a lighthouse
        let phase = -2.95 + u_sweep * spacing * 1.65;
        (ease_in * ease_out, phase, p)
    }

    #[inline]
    fn beam_intensity(angle: f64, phase: f64) -> f64 {
        let spacing = std::f64::consts::TAU / NUM_BEAMS;
        let mut d = (angle - phase) % spacing;
        if d > spacing * 0.5 {
            d -= spacing;
        } else if d < -spacing * 0.5 {
            d += spacing;
        }
        let u = (d / BEAM_HALF_WIDTH).abs();
        if u >= 1.0 {
            0.0
        } else {
            let v = 1.0 - u * u;
            v * v
        }
    }

    fn update_lighthouse_rays(&mut self, e: &mut Engine) {
        if self.config.final_hold_time <= 0 || self.frame < self.ray_start {
            return;
        }
        let (env, phase, _) = self.flourish_params();
        for cell in &mut self.ray_cells {
            let state = if env <= 0.001 {
                0
            } else {
                let raw = Self::beam_intensity(cell.angle, phase) * cell.weight * env;
                if raw < 0.08 {
                    0
                } else {
                    ((raw * RAY_LEVELS as f64).ceil() as usize).clamp(1, RAY_LEVELS) as u8
                }
            };
            if state != cell.state {
                cell.state = state;
                if state > 0 {
                    e.set_visual(cell.slot, self.ray_visuals[state as usize - 1]);
                }
                e.set_visible(cell.slot, state > 0);
            }
        }
        // gently warm the rainbow letters as each lighthouse beam sweeps behind them
        let frame = self.frame;
        if frame >= self.clear_end {
            for &t in &self.solid_text {
                let c = &mut self.text[t as usize];
                if c.lit_at > frame || ((frame - c.lit_at) / RAMP_FRAMES) < (RAMP - 1) as i64 {
                    continue;
                }
                let level = if env <= 0.001 {
                    0
                } else {
                    let b = Self::beam_intensity(c.sun_angle, phase) * env;
                    if b > 0.62 {
                        2
                    } else if b > 0.26 {
                        1
                    } else {
                        0
                    }
                };
                if level != c.flourish_level {
                    c.flourish_level = level;
                    if frame >= c.glint_until {
                        let vis = match level {
                            2 => c.sun_kissed[1],
                            1 => c.sun_kissed[0],
                            _ => c.ramp[RAMP - 1],
                        };
                        e.set_visual(c.slot, vis);
                    }
                }
            }
        }
    }

    fn update_golden_drops(&mut self, e: &mut Engine) {
        if self.config.final_hold_time <= 0 || self.frame < self.ray_start {
            return;
        }
        let (env, phase, p) = self.flourish_params();
        let (bottom, top) = (e.canvas.bottom, e.canvas.top);
        let wind = self.config.rain_wind;
        let (slow, fast) = self.config.rain_speed;
        let can_respawn = p < 0.62 && self.frame < self.end_frame - 24;
        let sun_col = self.sun_target.column;
        let sun_row = self.sun_target.row;
        let left_spawn = self.gold_spawn_left;
        let right_spawn = self.gold_spawn_right;

        for i in 0..self.golden_drops.len() {
            if self.frame < self.golden_drops[i].start_frame {
                continue;
            }
            if !self.golden_drops[i].alive {
                if !can_respawn {
                    continue;
                }
                let d = &mut self.golden_drops[i];
                d.alive = true;
                d.col = e.rng.uniform(left_spawn, right_spawn);
                d.row = top as f64 + e.rng.uniform(0.0, 2.0);
                d.speed = e.rng.uniform(slow, fast) * if d.near { 0.72 } else { 0.54 };
                d.vis_state = u8::MAX;
            }
            if p >= 0.90 || self.frame >= self.end_frame {
                let d = &mut self.golden_drops[i];
                d.alive = false;
                e.set_visible(d.slot, false);
                continue;
            }
            let (col, row, speed, near) = {
                let d = &self.golden_drops[i];
                (d.col, d.row, d.speed, d.near)
            };
            let new_row = row - speed;
            let new_col = col - speed * wind;
            let mut landed = None;
            if near {
                let (r0, r1) = (row.round() as i64, new_row.round() as i64);
                let mut r = r0 - 1;
                while r >= r1.max(bottom - 1) {
                    let c = (col - (row - r as f64) * wind).round() as i64;
                    if let Some(t) = self.solid_at(e, c, r) {
                        landed = Some((c, r, Some(t)));
                        break;
                    }
                    r -= 1;
                }
            }
            if landed.is_none() && new_row.round() < bottom as f64 {
                landed = Some((new_col.round() as i64, bottom - 1, None));
            }
            if let Some((c, r, hit)) = landed {
                if p < 0.85 && self.solid_at(e, c, r + 1).is_none() {
                    self.splash(e, c, r + 1);
                }
                if let Some(t) = hit {
                    self.glint(t);
                }
                let d = &mut self.golden_drops[i];
                if !can_respawn {
                    d.alive = false;
                    e.set_visible(d.slot, false);
                    continue;
                }
                d.col = e.rng.uniform(left_spawn, right_spawn);
                d.row = top as f64 + e.rng.uniform(0.0, 4.0);
                d.speed = e.rng.uniform(slow, fast) * if d.near { 0.72 } else { 0.54 };
            } else {
                let d = &mut self.golden_drops[i];
                d.row = new_row;
                d.col = new_col;
            }
            let d = &mut self.golden_drops[i];
            let ci = d.col.round() as i64;
            let ri = d.row.round() as i64;
            // glint bright white-gold when passing through a sweeping lighthouse beam
            let dx = (ci - sun_col) as f64 * 0.5;
            let dy = (ri - sun_row) as f64;
            let beam = Self::beam_intensity(dy.atan2(dx), phase) * env;
            let vs = if beam > 0.50 {
                2
            } else if beam > 0.16 {
                1
            } else {
                0
            };
            if vs != d.vis_state {
                d.vis_state = vs;
                e.set_visual(d.slot, d.visuals[vs as usize]);
            }
            e.set_coordinate(d.slot, Coord::new(ci, ri));
            e.set_visible(d.slot, true);
        }
    }

    /// The last frame: the text alone, settled.
    fn finish(&mut self, e: &mut Engine) {
        for c in &mut self.text {
            e.set_visual(c.slot, c.ramp[RAMP - 1]);
            c.flourish_level = 0;
            c.dirty = false;
        }
        self.dirty.clear();
        for i in 0..e.added_chars.len() {
            let slot = e.added_chars[i];
            e.set_visible(slot, false);
        }
    }
}

impl Hooks for Sunshower {}

fn visual(e: &mut Engine, sym: Sym, fg: Option<Color>, bg: Option<Color>, bold: bool) -> Visual {
    let attrs = HAS_COLORS | if bold { BOLD } else { 0 };
    e.visuals.make(&e.symbols, VisualInfo { sym, fg, bg, attrs })
}

/// The input character's own appearance: its input colors and bold.
fn input_visual(e: &mut Engine, slot: u32) -> Visual {
    let (sym, fg, bg, bold) = (e.input_sym(slot), e.input_fg(slot), e.input_bg(slot), e.input_bold(slot));
    visual(e, sym, fg, bg, bold)
}

fn added(e: &mut Engine, symbol: &str, coord: Coord, layer: i32) -> u32 {
    let sym = e.sym(symbol);
    let slot = e.add_character_sym(sym, coord);
    e.set_layer(slot, layer);
    e.set_visible(slot, false);
    slot
}

fn mix(color: Color, target: Color, factor: f64) -> Color {
    let (a, b) = (color.rgb_ints(), target.rgb_ints());
    let c = |x: u8, y: u8| (x as f64 + (y as f64 - x as f64) * factor).round().clamp(0.0, 255.0) as u8;
    Color::from_rgb(c(a.0, b.0), c(a.1, b.1), c(a.2, b.2))
}

fn hex(s: &str) -> Result<Color, EngineError> {
    Color::from_hex(s).map_err(EngineError::Other)
}

impl Effect for Sunshower {
    fn build(&mut self, e: &mut Engine) -> Result<(), EngineError> {
        let config = self.config.clone();
        let handling = e.existing_color_handling();
        let (dim, sky, white) = (hex(DIM_TEXT)?, hex(SKY)?, hex(WHITE)?);
        let canvas = e.canvas.clone();
        let colors = config.rainbow_colors.clone();
        let bands = colors.len();
        let cw = canvas.width.max(1);
        let ch = canvas.height.max(1);
        let area = (cw * ch) as f64;

        // the rainbow: a full arc standing on the bottom edge, centered on
        // the text, as wide as the canvas allows (round on screen: columns
        // are about half as wide as rows are tall)
        let cx = (canvas.text_left + canvas.text_right) / 2;
        let base = canvas.bottom;
        let half_w = (cx - canvas.left).min(canvas.right - cx).max(1);
        let mut ry = ((canvas.top - base) as f64 - 0.5).max(1.0);
        let rx = (ry * 2.0).min(half_w as f64 - 0.5).max(1.0);
        ry = ry.min(rx);
        let band_rows = (ry * 0.3 / bands as f64).round().max(1.0);
        let band_w = band_rows / ry;
        let angle = |col: i64, row: i64| {
            let (u, v) = ((col - cx) as f64 / rx, ((row - base) as f64 + 0.5) / ry);
            (u, v, 1.0 - v.atan2(u) / std::f64::consts::PI)
        };

        // sun position (computed early so text and lighthouse rays know its angle):
        // upper-right outside the rainbow arc, staying near the composition on ultrawide
        let sun_r = (ch as f64 / 10.0).clamp(2.2, 6.0);
        let ray_len = (sun_r * 0.8).round().max(2.0) as usize;
        self.ray_len = ray_len;
        let reach = sun_r + ray_len as f64 + 0.5;
        let sun_col = (cx + (rx * 0.88) as i64)
            .min(canvas.right - (reach * 2.0) as i64)
            .max(canvas.left);
        self.sun_target = Coord::new(
            sun_col,
            (canvas.top - sun_r.ceil() as i64).max(canvas.bottom),
        );
        self.sun_start_row = canvas.bottom - reach.ceil() as i64 - 1;
        let sun_warm = mix(config.sun_color, white, 0.30);

        // the text: dimmed until the rainbow's light passes, then glowing in
        // bands concentric with the arc
        let text = e.get_characters(CharacterFilter::default(), CharacterSort::TopToBottomLeftToRight);
        // bands: gentle arcs over the text, echoing the rainbow (a much
        // larger circle than the sky arc, so they read as bowed stripes)
        let (trx, try_) = {
            let r = (canvas.text_height.max(1) as f64 * 2.5).max(canvas.text_width.max(1) as f64 * 0.45);
            (r * 2.0, r)
        };
        let tbase = canvas.text_bottom as f64 - try_ * 0.8;
        let radius = |coord: Coord| {
            let (u, v) = ((coord.column - cx) as f64 / trx, (coord.row as f64 - tbase) / try_);
            (u * u + v * v).sqrt()
        };
        let (mut rmin, mut rmax) = (f64::MAX, f64::MIN);
        for &slot in &text {
            let r = radius(e.input_coord(slot));
            rmin = rmin.min(r);
            rmax = rmax.max(r);
        }
        let glint_dim_color = mix(dim, hex("bcd3e6")?, 0.6);
        self.solid = vec![u32::MAX; (cw * ch) as usize];
        for (index, &slot) in text.iter().enumerate() {
            let coord = e.input_coord(slot);
            let sym = e.input_sym(slot);
            let space = e.symbol(sym) == " ";
            let keep_input = handling == ExistingColorHandling::Always && e.uses_preexisting_colors(slot);
            let r = radius(coord);
            let band = if rmax > rmin {
                (((rmax - r) / (rmax - rmin)) * bands as f64) as usize
            } else {
                0
            }
            .min(bands - 1);
            let (dimmed, glint_dim, ramp, glint_lit, sun_kissed) = if keep_input {
                let v = input_visual(e, slot);
                (v, v, [v; RAMP], v, [v, v])
            } else {
                let dimmed = visual(e, sym, Some(dim), None, false);
                let glint_dim = visual(e, sym, Some(glint_dim_color), None, false);
                let fin = if handling == ExistingColorHandling::Dynamic {
                    e.input_fg(slot)
                } else {
                    Some(colors[band])
                };
                let fin_bg = if handling == ExistingColorHandling::Dynamic {
                    e.input_bg(slot)
                } else {
                    None
                };
                let mut ramp = [dimmed; RAMP];
                for (k, v) in ramp.iter_mut().enumerate() {
                    let t = k as f64 / (RAMP - 1) as f64;
                    *v = match fin {
                        Some(c) => visual(e, sym, Some(mix(white, c, t * t)), None, true),
                        None => visual(e, sym, Some(white), None, true),
                    };
                }
                ramp[RAMP - 1] = if handling == ExistingColorHandling::Dynamic {
                    input_visual(e, slot)
                } else {
                    ramp[RAMP - 1]
                };
                let glint_lit = match fin {
                    Some(c) => visual(e, sym, Some(mix(c, white, 0.55)), fin_bg, true),
                    None => ramp[RAMP - 1],
                };
                let sun_kissed = match fin {
                    Some(c) => [
                        visual(e, sym, Some(mix(c, sun_warm, 0.22)), fin_bg, true),
                        visual(e, sym, Some(mix(c, sun_warm, 0.42)), fin_bg, true),
                    ],
                    None => [ramp[RAMP - 1], ramp[RAMP - 1]],
                };
                (dimmed, glint_dim, ramp, glint_lit, sun_kissed)
            };
            e.set_layer(slot, if space { LAYER_SPACE } else { LAYER_TEXT });
            e.set_visual(slot, dimmed);
            e.set_visible(slot, true);
            let (_, _, reveal) = angle(coord.column, coord.row);
            let sdx = (coord.column - self.sun_target.column) as f64 * 0.5;
            let sdy = (coord.row - self.sun_target.row) as f64;
            let sun_angle = sdy.atan2(sdx);
            if !space && canvas.coord_is_in_canvas(coord) {
                let i = ((coord.row - canvas.bottom) * cw + (coord.column - canvas.left)) as usize;
                if let Some(cell) = self.solid.get_mut(i) {
                    *cell = index as u32;
                }
                self.solid_text.push(index as u32);
            }
            self.text.push(TextChar {
                slot,
                reveal,
                sun_angle,
                dim: dimmed,
                glint_dim,
                ramp,
                glint_lit,
                sun_kissed,
                lit_at: i64::MAX,
                glint_until: 0,
                flourish_level: 0,
                dirty: false,
            });
        }
        self.order = (0..self.text.len() as u32).collect();
        self.order.sort_by(|&a, &b| self.text[a as usize].reveal.total_cmp(&self.text[b as usize].reveal));

        // rainbow visuals: fresh (bright leading edge), then the settled
        // color fading into the sky
        let block = e.sym("█");
        let shades = [block, e.sym("▓"), e.sym("▒"), e.sym("░")];
        for &color in &colors {
            let settled = mix(color, sky, 0.3);
            let mut v = [Visual(crate::fx::NONE); FADE + 1];
            v[0] = visual(e, block, Some(mix(color, white, 0.45)), None, false);
            for k in 0..FADE {
                // dissolve: solid, then ever lighter shading, dimming
                let t = k as f64 / FADE as f64;
                let sym = shades[(k * 5 / FADE).min(3)];
                v[k + 1] = visual(e, sym, Some(mix(settled, sky, t * 0.6)), None, false);
            }
            self.rainbow_visuals.push(v);
        }
        // the arc passes behind the text: no cells within a column of the
        // letters on each row, so the sky between the strokes stays clear
        let mut spans = vec![(i64::MAX, i64::MIN); ch as usize];
        for &t in &self.solid_text {
            let coord = e.input_coord(self.text[t as usize].slot);
            let span = &mut spans[(coord.row - canvas.bottom) as usize];
            span.0 = span.0.min(coord.column - 1);
            span.1 = span.1.max(coord.column + 1);
        }
        for row in base..=canvas.top {
            let span = spans[(row - canvas.bottom) as usize];
            for col in canvas.left..=canvas.right {
                if col >= span.0 && col <= span.1 {
                    continue;
                }
                let (u, v, reveal) = angle(col, row);
                let r = (u * u + v * v).sqrt();
                let depth = (1.0 - r) / band_w;
                if depth < 0.0 || depth >= bands as f64 {
                    continue;
                }
                let slot = e.add_character_sym(block, Coord::new(col, row));
                e.set_layer(slot, LAYER_RAINBOW);
                e.set_visible(slot, false);
                let jitter = e.rng.random();
                self.rainbow.push(RainbowCell { slot, reveal, jitter, band: depth as usize, state: 0 });
            }
        }

        // the rain, two depths
        let count = ((config.rain_density as f64 * area / REF_AREA).round() as usize).clamp(1, 20_000);
        let wind = config.rain_wind;
        let span = canvas.right as f64 + wind * ch as f64 + 1.0;
        for _ in 0..count {
            let near = e.rng.random() < 0.5;
            let col = e.rng.uniform(canvas.left as f64, span);
            let row = e.rng.uniform(canvas.bottom as f64, canvas.top as f64 + 3.0);
            let speed = e.rng.uniform(config.rain_speed.0, config.rain_speed.1) * if near { 1.0 } else { 0.7 };
            let symbol = e.rng.choice(&config.rain_symbols).clone();
            let base_color = *e.rng.choice(&config.rain_colors);
            let color = if near { base_color } else { mix(base_color, sky, 0.45) };
            let sym = e.sym(&symbol);
            let slot = added(e, &symbol, Coord::new(col.round() as i64, row.round() as i64), LAYER_RAIN);
            let color_v = visual(e, sym, Some(color), None, false);
            let sunlit = visual(e, sym, Some(mix(color, config.sun_color, 0.7)), None, near);
            e.set_visual(slot, color_v);
            let fallaway = e.rng.random();
            self.rain.push(RainDrop {
                slot,
                col,
                row,
                speed,
                near,
                fallaway,
                alive: true,
                color: color_v,
                sunlit,
            });
        }

        // the splashes, a pool reused round robin (blue during storm, gold during flourish)
        let splash_color = config.rain_colors[2.min(config.rain_colors.len() - 1)];
        let gold_splash_color = mix(config.sun_color, white, 0.35);
        for (i, (symbol, _)) in SPLASH_STAGES.iter().enumerate() {
            let sym = e.sym(symbol);
            self.splash_visuals[i] = visual(e, sym, Some(splash_color), None, false);
            self.gold_splash_visuals[i] = visual(e, sym, Some(gold_splash_color), None, i == 0);
        }
        for _ in 0..(count / 3).clamp(4, 4000) {
            let slot = added(e, ".", Coord::new(canvas.left, canvas.bottom), LAYER_SPLASH);
            e.set_visual(slot, self.splash_visuals[0]);
            self.splashes.push(Splash { slot, born: -1_000_000 });
        }

        // the clouds: puffy blobs along the top, scaled with the height
        let scale = (ch as f64 / 24.0).clamp(1.0, 2.5);
        let rain_shades = [hex(CLOUD_RAIN[0])?, hex(CLOUD_RAIN[1])?];
        let sun_shades = [hex(CLOUD_SUN[0])?, hex(CLOUD_SUN[1])?];
        let cloud_syms = [e.sym("▄"), e.sym("█")];
        for sym in cloud_syms {
            for shade in 0..2 {
                let mut table = [[Visual(crate::fx::NONE); FADE]; LIGHT];
                for (l, row) in table.iter_mut().enumerate() {
                    let lit = mix(rain_shades[shade], sun_shades[shade], l as f64 / (LIGHT - 1) as f64);
                    for (f, v) in row.iter_mut().enumerate() {
                        *v = visual(e, sym, Some(mix(lit, sky, f as f64 / FADE as f64)), None, false);
                    }
                }
                self.cloud_visuals.push(table);
            }
        }
        let cloud_count = ((cw as f64 / (20.0 * scale)).round() as usize).clamp(1, 40);
        let spacing = (cw as f64 + 30.0 * scale) / cloud_count as f64;
        let room = (canvas.top - canvas.text_top - 1).max(0);
        for index in 0..cloud_count {
            let width = (e.rng.uniform(12.0, 26.0) * scale).round() as i64;
            let height = (e.rng.uniform(2.0, 3.6) * scale).round().max(2.0) as i64;
            let puffs = (width / 6).max(2);
            let mut shape = vec![false; (width * height) as usize];
            for p in 0..puffs {
                let px = (p as f64 + 0.5) / puffs as f64 * width as f64 + e.rng.uniform(-1.5, 1.5);
                let pr = height as f64 * e.rng.uniform(0.6, 1.05);
                let edge = (width as f64 / 2.0 - (px - width as f64 / 2.0).abs()) / 2.0 + 0.6;
                let pr = pr.min(edge.max(1.0));
                for dy in 0..height {
                    for dx in 0..width {
                        let (u, v) = ((dx as f64 + 0.5 - px) / (pr * 2.0), (dy as f64 + 0.5) / pr);
                        if u * u + v * v <= 1.0 {
                            shape[(dy * width + dx) as usize] = true;
                        }
                    }
                }
            }
            let mut parts = Vec::new();
            for dy in 0..height {
                for dx in 0..width {
                    if !shape[(dy * width + dx) as usize] {
                        continue;
                    }
                    let above = dy + 1 < height && shape[((dy + 1) * width + dx) as usize];
                    let sym = if above { 1 } else { 0 };
                    let shade = if dy + 1 >= height - 1 || !above { 0 } else { 1 };
                    let slot = added(e, if above { "█" } else { "▄" }, Coord::new(0, 0), LAYER_CLOUD);
                    parts.push(CloudPart { slot, offset: Coord::new(dx, dy), kind: sym * 2 + shade });
                }
            }
            let lift = if room > height { e.rng.randint(0, (room - height).min(3 * scale as i64)) } else { 0 };
            self.clouds.push(Cloud {
                parts,
                col: canvas.left as f64 + index as f64 * spacing + e.rng.uniform(-3.0, 3.0),
                row: canvas.top - height + 2 - lift - (index % 2) as i64,
                speed: e.rng.uniform(0.012, 0.03) * scale,
                width,
            });
        }

        // the sun: a disc with rays, in the top right corner (outside the
        // arc), rising from below the bottom edge behind the clouds
        let sun_shades = [config.sun_color, mix(config.sun_color, white, 0.35)];
        let ray_syms = ["—", "/", "|", "\\", "·"];
        let mut sun_syms: Vec<(Sym, Color, bool)> = vec![(block, sun_shades[0], true), (e.sym("▄"), sun_shades[0], true), (e.sym("▀"), sun_shades[0], true)];
        for s in ray_syms {
            sun_syms.push((e.sym(s), sun_shades[1], true));
        }
        for &(sym, color, bold) in &sun_syms {
            let mut v = [Visual(crate::fx::NONE); FADE];
            for (f, slot) in v.iter_mut().enumerate() {
                *slot = visual(e, sym, Some(mix(color, sky, f as f64 / FADE as f64)), None, bold);
            }
            self.sun_visuals.push(v);
        }
        let rr = sun_r.ceil() as i64;
        let inside = |dx: f64, dy: f64| (dx / 2.0).powi(2) + dy * dy <= sun_r * sun_r;
        for dy in -rr..=rr {
            for dx in -(rr * 2 + 1)..=(rr * 2 + 1) {
                let (x, y) = (dx as f64, dy as f64);
                let (full, top, bottom) = (inside(x, y), inside(x, y + 0.25), inside(x, y - 0.25));
                let kind = if full {
                    0
                } else if bottom {
                    1
                } else if top {
                    2
                } else {
                    continue;
                };
                let sym = sun_syms[kind].0;
                let slot = e.add_character_sym(sym, Coord::new(0, 0));
                e.set_layer(slot, LAYER_SUN);
                e.set_visible(slot, false);
                self.sun.push(SunPart { slot, offset: Coord::new(dx, dy), ray: None, kind });
            }
        }
        for ray in 0..RAYS {
            let a = ray as f64 / RAYS as f64 * std::f64::consts::TAU;
            let kind = if ray % 2 == 1 {
                3 + 4
            } else {
                3 + match (ray / 2) % 4 {
                    0 => 0,
                    1 => 1,
                    2 => 2,
                    _ => 3,
                }
            };
            for step in 0..ray_len {
                let d = sun_r + 1.0 + step as f64;
                let offset = Coord::new((a.cos() * d * 2.0).round() as i64, (a.sin() * d).round() as i64);
                let slot = e.add_character_sym(sun_syms[kind].0, Coord::new(0, 0));
                e.set_layer(slot, LAYER_SUN);
                e.set_visible(slot, false);
                self.sun.push(SunPart { slot, offset, ray: Some((ray, step)), kind });
            }
        }

        // the timeline: the sky clears once the rainbow and the sunrise are
        // both done and the hold has passed
        self.rainbow_end = config.rainbow_start.saturating_add(config.rainbow_duration);
        self.sunrise_end = config.sun_start.saturating_add(config.sunrise_duration);
        self.clear_start = self.rainbow_end.max(self.sunrise_end).saturating_add(config.hold_time);
        self.clear_end = self.clear_start.saturating_add(config.clear_duration);
        self.ray_start = self.clear_start.saturating_add((config.clear_duration as f64 * 0.65) as i64);
        self.end_frame = self.clear_end.saturating_add(config.final_hold_time);

        // lighthouse sunbeams: soft volumetric golden rays sweeping slowly behind
        // the finished logo during the flourish, bounded to the logo-and-sun halo
        let black = Color::from_rgb(0, 0, 0);
        let space_sym = e.sym(" ");
        let shade_sym = e.sym("░");
        let bright_gold = mix(config.sun_color, white, 0.45);
        self.ray_visuals = [
            visual(e, space_sym, None, Some(mix(black, config.sun_color, 0.09)), false),
            visual(e, space_sym, None, Some(mix(black, config.sun_color, 0.16)), false),
            visual(e, space_sym, None, Some(mix(black, config.sun_color, 0.24)), false),
            visual(e, shade_sym, Some(mix(black, sun_warm, 0.45)), Some(mix(black, config.sun_color, 0.21)), false),
            visual(e, shade_sym, Some(mix(black, bright_gold, 0.62)), Some(mix(black, config.sun_color, 0.28)), false),
        ];

        let (t_left, t_right, t_bottom, t_top) = if !self.solid_text.is_empty() {
            (
                canvas.text_left.clamp(canvas.left, canvas.right),
                canvas.text_right.clamp(canvas.left, canvas.right),
                canvas.text_bottom.clamp(canvas.bottom, canvas.top),
                canvas.text_top.clamp(canvas.bottom, canvas.top),
            )
        } else {
            (cx, cx, (canvas.bottom + canvas.top) / 2, (canvas.bottom + canvas.top) / 2)
        };
        let pad_x = ((t_right - t_left + 1) / 2).clamp(18, 52);
        let pad_y = ((t_top - t_bottom + 1) * 3 / 2).clamp(8, 18);
        let mut box_left = (t_left - pad_x).max(canvas.left);
        let mut box_right = (t_right + pad_x).max(self.sun_target.column).min(canvas.right);
        let mut box_bottom = (t_bottom - pad_y).max(canvas.bottom);
        let mut box_top = (t_top + pad_y).max(self.sun_target.row).min(canvas.top);
        // keep ray cell count bounded on massive canvases (e.g., 300x90)
        let box_w = (box_right - box_left + 1).max(1);
        let box_h = (box_top - box_bottom + 1).max(1);
        if box_w * box_h > 9000 {
            let s = (9000.0 / (box_w * box_h) as f64).sqrt();
            let nw = ((box_w as f64 * s).round() as i64).max(1);
            let nh = ((box_h as f64 * s).round() as i64).max(1);
            let bcx = (t_left + t_right) / 2;
            let bcy = (t_bottom + t_top) / 2;
            box_left = (bcx - nw / 2).max(canvas.left);
            box_right = (box_left + nw - 1).min(canvas.right);
            box_bottom = (bcy - nh / 2).max(canvas.bottom);
            box_top = (box_bottom + nh - 1).min(canvas.top);
        }
        let bcx = (box_left + box_right) as f64 * 0.5;
        let bcy = (box_bottom + box_top) as f64 * 0.5;
        let bhx = ((box_right - box_left) as f64 * 0.5).max(1.0);
        let bhy = ((box_top - box_bottom) as f64 * 0.5).max(1.0);
        let max_d = ((box_right - box_left).max(1) as f64 * 0.5)
            .hypot((box_top - box_bottom).max(1) as f64)
            .max(10.0);

        if config.final_hold_time > 0 {
            for row in box_bottom..=box_top {
                for col in box_left..=box_right {
                    if self.solid_at(e, col, row).is_some() {
                        continue;
                    }
                    let dx = (col - self.sun_target.column) as f64 * 0.5;
                    let dy = (row - self.sun_target.row) as f64;
                    let dist = (dx * dx + dy * dy).sqrt();
                    if dist < sun_r * 0.9 {
                        continue;
                    }
                    let near_fade = ((dist - sun_r * 0.9) / (sun_r * 0.8).max(1.0)).clamp(0.0, 1.0);
                    let dist_fade = (1.0 - (dist / (max_d * 1.18)).powi(2)).clamp(0.0, 1.0);
                    let ex = ((col as f64 - bcx) / bhx).abs();
                    let ey = ((row as f64 - bcy) / bhy).abs();
                    let edge_t = ((ex.max(ey) - 0.70) / 0.30).clamp(0.0, 1.0);
                    let edge_fade = (1.0 - edge_t) * (1.0 - edge_t);
                    let weight = near_fade * dist_fade * edge_fade;
                    if weight < 0.06 {
                        continue;
                    }
                    let slot = e.add_character_sym(space_sym, Coord::new(col, row));
                    e.set_layer(slot, LAYER_RAY);
                    e.set_visible(slot, false);
                    self.ray_cells.push(RayCell { slot, angle: dy.atan2(dx), weight, state: 0 });
                }
            }

            // a few last raindrops that glint gold as they drift past the logo
            self.gold_spawn_left = box_left as f64;
            self.gold_spawn_right = box_right as f64 + wind * ch as f64 + 1.0;
            let gold_count = ((cw as f64 / 9.0).round() as usize).clamp(12, 32);
            let soft_gold = mix(config.sun_color, sky, 0.15);
            let glint_gold = mix(config.sun_color, white, 0.78);
            let gold_syms = ["/", "/", "'", "·"];
            for index in 0..gold_count {
                let near = index % 3 != 0;
                let sym_str = gold_syms[index % gold_syms.len()];
                let sym = e.sym(sym_str);
                let layer = if near { LAYER_SPLASH } else { LAYER_CLOUD };
                let slot = added(e, sym_str, Coord::new(canvas.left, canvas.top), layer);
                let visuals = [
                    visual(e, sym, Some(soft_gold), None, false),
                    visual(e, sym, Some(config.sun_color), None, true),
                    visual(e, sym, Some(glint_gold), None, true),
                ];
                e.set_visual(slot, visuals[0]);
                let start_frame = self.ray_start + (index as i64 * 11) % 90;
                self.golden_drops.push(GoldenDrop {
                    slot,
                    col: self.gold_spawn_left,
                    row: canvas.top as f64,
                    speed: config.rain_speed.0,
                    near,
                    start_frame,
                    alive: false,
                    visuals,
                    vis_state: u8::MAX,
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
        if self.frame == self.end_frame {
            self.finish(e);
        } else {
            self.update_rain(e);
            self.update_splashes(e);
            self.update_clouds(e);
            self.update_sun(e);
            self.update_rainbow(e);
            self.update_lighthouse_rays(e);
            self.update_golden_drops(e);
            self.update_text(e);
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
        config: SunshowerConfig,
    }

    fn config(args: &[&str]) -> SunshowerConfig {
        let mut argv = vec!["sunshower"];
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

    /// Runs the effect to completion; returns the frame count.
    fn run(effect: &mut Sunshower, e: &mut Engine) -> u64 {
        effect.build(e).unwrap();
        let mut frames = 0;
        while effect.next_frame(e) {
            e.render_here();
            frames += 1;
            assert!(frames < 100_000, "sunshower does not end");
        }
        frames
    }

    /// The last frame shows the input text alone, at its input coordinates.
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

    const DEFAULT_FRAMES: u64 = 330 + 300 + 260 + 220 + 380 + 1;

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
            let mut effect = Sunshower::new(config(&[]));
            assert_eq!(run(&mut effect, &mut e), DEFAULT_FRAMES, "{input:?} {w}x{h}");
            assert_settled(&e);
        }
    }

    #[test]
    fn final_text_is_in_the_rainbow() {
        let mut e = engine("OMARCHY\nhello world\n", 60, 20, ExistingColorHandling::Ignore);
        let mut effect = Sunshower::new(config(&[]));
        run(&mut effect, &mut e);
        let colors = config(&[]).rainbow_colors;
        for &slot in &e.input_chars {
            if e.symbol(e.input_sym(slot)) == " " {
                continue;
            }
            let fg = e.visual_info(e.current_visual(slot)).fg.unwrap();
            assert!(colors.contains(&fg), "{fg:?}");
        }
    }

    #[test]
    fn timing_options_feed_the_run_length() {
        let frames = |args: &[&str]| {
            let mut e = engine("OMARCHY\n", 40, 12, ExistingColorHandling::Ignore);
            run(&mut Sunshower::new(config(args)), &mut e)
        };
        let base = frames(&[]);
        assert_eq!(base, DEFAULT_FRAMES);
        assert_eq!(frames(&["--sun-start", "1000"]), base + 1000 + 260 - 630);
        assert_eq!(frames(&["--sunrise-duration", "1000"]), base + 150 + 1000 - 630);
        assert_eq!(frames(&["--rainbow-start", "331"]), base + 1);
        assert_eq!(frames(&["--rainbow-duration", "301"]), base + 1);
        assert_eq!(frames(&["--hold-time", "261"]), base + 1);
        assert_eq!(frames(&["--clear-duration", "221"]), base + 1);
        assert_eq!(frames(&["--final-hold-time", "381"]), base + 1);
        assert_eq!(
            frames(&["--rainbow-start", "0", "--rainbow-duration", "1", "--sun-start", "0",
                "--sunrise-duration", "1", "--hold-time", "0", "--clear-duration", "1",
                "--final-hold-time", "0"]),
            3
        );
    }

    #[test]
    fn the_sun_rises_when_it_starts_late() {
        let mut e = engine("OMARCHY\n", 40, 20, ExistingColorHandling::Ignore);
        let mut effect = Sunshower::new(config(&["--sun-start", "1000"]));
        effect.build(&mut e).unwrap();
        let mut seen = false;
        while effect.next_frame(&mut e) {
            e.render_here();
            seen |= effect.sun.iter().any(|p| e.is_visible(p.slot));
        }
        assert!(seen);
        assert_settled(&e);
    }

    #[test]
    fn near_rain_lands_on_the_letters() {
        let mut e = engine("██████████\n██████████\n", 40, 20, ExistingColorHandling::Ignore);
        let mut effect = Sunshower::new(config(&[]));
        effect.build(&mut e).unwrap();
        let mut glints = 0;
        for _ in 0..300 {
            effect.next_frame(&mut e);
            e.render_here();
            glints += effect.text.iter().filter(|c| c.glint_until > effect.frame).count();
        }
        assert!(glints > 0);
    }

    #[test]
    fn dynamic_keeps_input_colors() {
        let input = "\x1b[38;2;255;0;0mred\x1b[0m plain\n";
        for handling in [ExistingColorHandling::Dynamic, ExistingColorHandling::Always] {
            let mut e = engine(input, 40, 10, handling);
            run(&mut Sunshower::new(config(&[])), &mut e);
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
            let mut effect = Sunshower::new(config(&[]));
            effect.build(&mut e).unwrap();
            for _ in 0..700 {
                effect.next_frame(&mut e);
                e.render_here();
            }
            (0..e.char_count() as u32)
                .map(|s| (e.coord(s), e.is_visible(s), e.current_visual(s).0))
                .collect::<Vec<_>>()
        };
        assert_eq!(state(), state());
    }
}
