//! airstrike: jets dive-bomb the text. Each bomb blows the glyphs around it
//! into burning rubble, then the scattered glyphs pull themselves back
//! together.
//!
//! Original effect by Lukas Innig (@derluke), https://github.com/derluke/ttfx, MIT.
//! Rewritten for the fx engine; every character is driven by hand each frame
//! (no scenes or paths), the way the original drove the old engine.
//!
//! Timeline: jet `i` launches at `i * launch-delay` from alternating sides,
//! cruising above the text at `flight-speed` cells per frame with an ember
//! trail. It dives toward its release point, drops a bomb that falls onto a
//! target glyph (targets are spread across the text and hit in a seeded
//! order), then pulls up and leaves on afterburner. On impact a shockwave
//! ring and a fireball burst out, smoke rises, and the glyphs within
//! `blast-radius` (assigned to their nearest bomb) are flung out as debris
//! for `debris-duration` frames: white hot, cooling through the fire colors
//! to soot, bouncing to rest on a rubble line under the text. After that
//! (staggered over a third of `debris-duration`) each glyph lifts out of
//! the rubble and arcs home over `reassembly-duration` frames, warming from
//! soot back into its final color. Once the text is restored and the bombing
//! smoke clears, a final victory jet streaks low beneath the logo over
//! `final-hold-time` frames, igniting a glowing contrail underline that
//! evaporates while hot embers drift up off the letters and burn out.

use clap::Args;

use crate::cli::parse_color;
use crate::effects::common::{
    parse_gradient_direction, parse_gradient_steps, parse_non_negative_int, parse_positive_float,
    parse_positive_int,
};
use crate::engine::animation::ExistingColorHandling;
use crate::engine::error::EngineError;
use crate::engine::terminal::{CharacterFilter, CharacterSort};
use crate::fx::run::Effect;
use crate::fx::visual::{VisualInfo, BOLD, HAS_COLORS};
use crate::fx::{Engine, Hooks, Sym, Visual};
use crate::utils::geometry::Coord;
use crate::utils::graphics::{Color, ColorPair, Gradient, GradientDirection};

#[derive(Args, Debug, Clone)]
pub struct AirstrikeConfig {
    /// Number of planes which strike the text.
    #[arg(long = "plane-count", default_value_t = 6, value_parser = parse_positive_int)]
    pub plane_count: i64,

    /// Plane cruise speed in terminal cells per frame.
    #[arg(long = "flight-speed", default_value_t = 0.45, value_parser = parse_positive_float)]
    pub flight_speed: f64,

    /// Frames between successive plane launches.
    #[arg(long = "launch-delay", default_value_t = 75, value_parser = parse_non_negative_int)]
    pub launch_delay: i64,

    /// Radius, in terminal cells, affected by each impact (half as many rows).
    #[arg(long = "blast-radius", default_value_t = 20, value_parser = parse_positive_int)]
    pub blast_radius: i64,

    /// Frames the text glyphs spend as flying and smouldering debris.
    #[arg(long = "debris-duration", default_value_t = 110, value_parser = parse_positive_int)]
    pub debris_duration: i64,

    /// Frames the scattered text takes to reassemble.
    #[arg(long = "reassembly-duration", default_value_t = 150, value_parser = parse_positive_int)]
    pub reassembly_duration: i64,

    /// Frames for the victory flyby flourish and final hold after the smoke clears.
    #[arg(long = "final-hold-time", default_value_t = 320, value_parser = parse_non_negative_int)]
    pub final_hold_time: i64,

    /// Number of fire and shrapnel particles emitted by each impact.
    #[arg(long = "fire-particles", default_value_t = 52, value_parser = parse_positive_int)]
    pub fire_particles: i64,

    /// Color of the incoming aircraft and their bombs.
    #[arg(long = "plane-color", default_value = "b8c4d6", value_parser = parse_color)]
    pub plane_color: Color,

    /// Space separated list of colors used by the fireball, hottest first.
    #[arg(long = "fire-colors", num_args = 1.., value_parser = parse_color,
          default_values = ["fff3a3", "ffb000", "ff4d00", "7a1f00"])]
    pub fire_colors: Vec<Color>,

    /// Space separated list of colors for the restored text gradient.
    #[arg(long = "final-gradient-stops", num_args = 1.., value_parser = parse_color,
          default_values = ["ff5f00", "ffd166", "fff3b0"])]
    pub final_gradient_stops: Vec<Color>,

    /// Number of gradient steps to use.
    #[arg(long = "final-gradient-steps", num_args = 1.., value_parser = parse_gradient_steps,
          default_values = ["12"])]
    pub final_gradient_steps: Vec<i64>,

    /// Direction of the restored text gradient.
    #[arg(long = "final-gradient-direction", default_value = "diagonal", value_parser = parse_gradient_direction)]
    pub final_gradient_direction: GradientDirection,
}

/// Fire and trail particles change glyph as they cool: `*`, `+`, `.`.
const EMBER_SYMBOLS: [&str; 3] = ["*", "+", "."];
/// Trail particles live randint(TRAIL_LIFE) frames.
const TRAIL_LIFE: (i64, i64) = (24, 43);
/// Fire particles live randint(FIRE_LIFE) frames.
const FIRE_LIFE: (i64, i64) = (28, 66);
/// Planes drop a trail particle every this many frames.
const TRAIL_EVERY: i64 = 3;
/// Frames a jet takes to dive from cruise to release altitude.
const DIVE: f64 = 45.0;
/// Frames a jet takes to pull back up after the release.
const CLIMB: f64 = 30.0;
/// Afterburner: cells per frame squared after the release.
const AFTERBURNER: f64 = 0.012;
/// Frames the shockwave ring expands.
const RING_LIFE: i64 = 16;
/// Smoke puffs per impact, their start delay and lifetime ranges.
const SMOKE_PUFFS: i64 = 12;
const SMOKE_DELAY: (i64, i64) = (4, 30);
const SMOKE_LIFE: (i64, i64) = (70, 120);
const SMOKE_SYMBOLS: [&str; 4] = ["O", "o", "o", "."];
const SMOKE_COLORS: [&str; 4] = ["7d7571", "5e5653", "443f3d", "2e2a29"];
/// Rubble piles at most this many glyphs high.
const PILE_MAX: u16 = 4;
/// The color the debris cools to.
const SOOT: &str = "6b625f";
/// Debris gravity, in rows per frame squared.
const GRAVITY: f64 = 0.018;
/// Colors in the cooling (fire to soot) and warming (soot to final) ramps.
const RAMP: usize = 10;

/// The jet, flying right: (symbol, column, row) from the nose. Flying left
/// mirrors it. The first part is the afterburner flame.
const JET: [(&str, i64, i64); 10] = [
    ("~", -5, 0),
    ("[", -4, 0),
    ("=", -3, 0),
    ("=", -2, 0),
    ("o", -1, 0),
    (">", 0, 0),
    ("\\", -3, 1),
    ("\\", -2, 1),
    ("/", -3, -1),
    ("/", -2, -1),
];

struct Plane {
    /// Sprite slots and their offsets from the nose; parts[0] is the flame.
    parts: Vec<(u32, Coord)>,
    bomb: u32,
    /// 1 flying right, -1 flying left.
    dir: f64,
    start_x: f64,
    release_x: f64,
    /// Cruise and release altitude (rows).
    high: f64,
    low: f64,
    target: Coord,
    launch: i64,
    release: i64,
    impact: i64,
    exit: i64,
    /// Bomb fall: frames and height.
    fall: f64,
    drop: f64,
    impacted: bool,
}

struct Debris {
    slot: u32,
    home: Coord,
    plane: usize,
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    /// First frame of the trip home, and where it starts.
    homeward: i64,
    from: (f64, f64),
    /// Fire to soot, then soot to the settled look.
    cooling: Vec<Visual>,
    warming: Vec<Visual>,
    /// The text's settled look (also its look before the strike).
    settled: Visual,
    /// 0 waiting, 1 flying, 2 going home, 3 home.
    phase: u8,
    /// The rubble pile it rests on, once it lands.
    pile: Option<usize>,
}

struct Fire {
    slot: u32,
    plane: usize,
    vx: f64,
    vy: f64,
    lifetime: i64,
}

struct Smoke {
    slot: u32,
    plane: usize,
    delay: i64,
    x: f64,
    vx: f64,
    vy: f64,
    lifetime: i64,
}

struct Trail {
    slot: u32,
    born: i64,
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    lifetime: i64,
}

struct ContrailCell {
    slot: u32,
    col: i64,
    row: i64,
    ignite_frame: i64,
    life: i64,
    outer: bool,
}

struct FlourishEmber {
    slot: u32,
    born: i64,
    life: i64,
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    sway_phase: f64,
    sway_amp: f64,
}

struct LogoGlyph {
    slot: u32,
    home: Coord,
    settled: Visual,
    flare: [Visual; 3],
    flared: bool,
}

struct VictoryFlyby {
    /// Sprite slots and offsets from the nose; parts[0..2] are the afterburner flames.
    parts: Vec<(u32, Coord)>,
    start_frame: i64,
    pass_frames: i64,
    start_x: f64,
    end_x: f64,
    base_row: f64,
    text_bottom: i64,
    climb_start_x: f64,
    climb_height: f64,
    contrail: Vec<ContrailCell>,
    embers: Vec<FlourishEmber>,
    contrail_hot: [Visual; 3],
    contrail_body: [Visual; 4],
    contrail_outer: [Visual; 4],
    ember_looks: Vec<[Visual; 3]>,
}

pub struct Airstrike {
    config: AirstrikeConfig,
    planes: Vec<Plane>,
    debris: Vec<Debris>,
    logo_glyphs: Vec<LogoGlyph>,
    flyby: Option<VictoryFlyby>,
    fire: Vec<Fire>,
    smoke: Vec<Smoke>,
    /// Shockwave slots per plane.
    rings: Vec<Vec<u32>>,
    /// Live trail particles; `spare` holds hidden slots to reuse.
    trails: Vec<Trail>,
    spare: Vec<u32>,
    /// [ember symbol][fire color] visuals.
    embers: Vec<[Visual; 3]>,
    ember_syms: [Sym; 3],
    /// [smoke stage] visuals.
    puffs: [Visual; 4],
    /// [fire color][- / | \] visuals for the shockwave.
    ring_looks: Vec<[Visual; 4]>,
    /// The bomb, level / diving / vertical, for each direction.
    bomb_looks: [[Visual; 3]; 2],
    /// The afterburner flame, two flickers.
    flames: [Visual; 2],
    /// Rubble line, the pile height on each of its columns, side walls.
    floor: f64,
    piles: Vec<u16>,
    walls: (f64, f64),
    frame: i64,
    end_frame: i64,
}

fn smooth(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

fn mix(a: Color, b: Color, t: f64) -> Color {
    let (a, b) = (a.rgb_ints(), b.rgb_ints());
    let f = |x: u8, y: u8| (x as f64 + (y as f64 - x as f64) * t).round().clamp(0.0, 255.0) as u8;
    Color::from_rgb(f(a.0, b.0), f(a.1, b.1), f(a.2, b.2))
}

/// `n` colors evenly along the stops.
fn ramp(stops: &[Color], n: usize) -> Vec<Color> {
    (0..n)
        .map(|i| {
            let at = i as f64 / (n - 1) as f64 * (stops.len() - 1) as f64;
            let k = (at.floor() as usize).min(stops.len().saturating_sub(2));
            if stops.len() == 1 {
                stops[0]
            } else {
                mix(stops[k], stops[k + 1], at - k as f64)
            }
        })
        .collect()
}

fn round(x: f64, y: f64) -> Coord {
    Coord::new(x.round() as i64, y.round() as i64)
}

impl Airstrike {
    pub fn new(config: AirstrikeConfig) -> Self {
        Airstrike {
            config,
            planes: Vec::new(),
            debris: Vec::new(),
            logo_glyphs: Vec::new(),
            flyby: None,
            fire: Vec::new(),
            smoke: Vec::new(),
            rings: Vec::new(),
            trails: Vec::new(),
            spare: Vec::new(),
            embers: Vec::new(),
            ember_syms: [Sym(0); 3],
            puffs: [Visual(0); 4],
            ring_looks: Vec::new(),
            bomb_looks: [[Visual(0); 3]; 2],
            flames: [Visual(0); 2],
            floor: 0.0,
            piles: Vec::new(),
            walls: (0.0, 0.0),
            frame: 0,
            end_frame: 0,
        }
    }

    /// The ember visual for a particle `ratio` through its life; `fire_cut`
    /// is where `*` turns to `+`.
    fn ember(&self, ratio: f64, fire_cut: f64) -> Visual {
        let n = self.embers.len();
        let color = ((ratio * n as f64) as usize).min(n - 1);
        let symbol = if ratio < fire_cut {
            0
        } else if ratio < 0.65 {
            1
        } else {
            2
        };
        self.embers[color][symbol]
    }

    /// Where plane `p` is (its nose) at frame `f`.
    fn plane_at(&self, p: &Plane, f: i64) -> (f64, f64) {
        let speed = self.config.flight_speed;
        if f <= p.release {
            let x = p.start_x + p.dir * speed * (f - p.launch) as f64;
            let to_release = (p.release - f) as f64;
            let y = p.low + (p.high - p.low) * smooth(to_release / DIVE);
            (x, y)
        } else {
            let t = (f - p.release) as f64;
            let x = p.release_x + p.dir * (speed * t + AFTERBURNER * t * t);
            let y = p.low + (p.high + 1.0 - p.low) * smooth(t / CLIMB);
            (x, y)
        }
    }

    fn impact(&mut self, e: &mut Engine, index: usize) {
        let plane = &mut self.planes[index];
        plane.impacted = true;
        e.set_visible(plane.bomb, false);
        let target = plane.target;
        let radius = self.config.blast_radius as f64;
        let reach = radius * 1.35;
        let flight = self.config.debris_duration;
        let impact = plane.impact;
        for piece in self.debris.iter_mut().filter(|d| d.plane == index) {
            // distances in "visual" cells: a row is two columns tall
            let dx = (piece.home.column - target.column) as f64;
            let dy = 2.0 * (piece.home.row - target.row) as f64;
            let distance = (dx * dx + dy * dy).sqrt();
            let (ux, uy) = if distance < 0.5 {
                let a = e.rng.uniform(0.0, std::f64::consts::PI);
                (a.cos(), a.sin())
            } else {
                (dx / distance, dy / distance)
            };
            let force = (1.0 - distance / reach).clamp(0.15, 1.0);
            let speed = 0.2 + force * 0.75;
            piece.vx = ux * speed + e.rng.uniform(-0.12, 0.12);
            piece.vy = uy * speed * 0.5 + e.rng.uniform(0.12, 0.42) * (0.4 + force);
            piece.x = piece.home.column as f64;
            piece.y = piece.home.row as f64;
            // outer glyphs come home first, the crater last
            let stagger = (flight / 3) as f64 * (1.0 - distance / reach).clamp(0.0, 1.0);
            piece.homeward = impact
                .saturating_add(flight)
                .saturating_add((stagger + e.rng.uniform(0.0, 4.0)).min((flight / 3) as f64) as i64);
            piece.phase = 1;
        }
    }

    fn emit_trail(&mut self, e: &mut Engine, x: f64, y: f64, dir: f64) {
        let origin_x = x - dir * 6.0;
        let origin_y = y + e.rng.uniform(-0.25, 0.25);
        let vx = -dir * e.rng.uniform(0.03, 0.11);
        let vy = e.rng.uniform(0.01, 0.08);
        let lifetime = e.rng.randint(TRAIL_LIFE.0, TRAIL_LIFE.1);
        let slot = match self.spare.pop() {
            Some(slot) => slot,
            None => {
                let slot = e.add_character_sym(self.ember_syms[0], Coord::new(0, 0));
                e.set_layer(slot, 2);
                slot
            }
        };
        self.trails.push(Trail {
            slot,
            born: self.frame,
            x: origin_x,
            y: origin_y,
            vx,
            vy,
            lifetime,
        });
    }

    fn update_planes(&mut self, e: &mut Engine) {
        let f = self.frame;
        for index in 0..self.planes.len() {
            let plane = &self.planes[index];
            if f < plane.launch || f > plane.exit {
                for &(slot, _) in &plane.parts {
                    e.set_visible(slot, false);
                }
                continue;
            }
            let (x, y) = self.plane_at(plane, f);
            let (column, row) = (x.round() as i64, y.round() as i64);
            for &(slot, offset) in &plane.parts {
                e.set_coordinate(slot, Coord::new(column + offset.column, row + offset.row));
                e.set_visible(slot, true);
            }
            let flame = plane.parts[0].0;
            e.set_visual(flame, self.flames[((f / 3) % 2) as usize]);

            // the bomb
            let bomb = plane.bomb;
            if f >= plane.release && f < plane.impact {
                let t = (f - plane.release) as f64;
                let s = t / plane.fall;
                let bx = plane.release_x + plane.dir * self.config.flight_speed * t;
                let by = plane.low - 1.0 - plane.drop * s * s;
                // visual slope: rows are twice as tall as columns
                let slope = 4.0 * plane.drop * t / (plane.fall * plane.fall)
                    / self.config.flight_speed;
                let look = if slope < 0.6 {
                    0
                } else if slope < 2.5 {
                    1
                } else {
                    2
                };
                let side = if plane.dir > 0.0 { 0 } else { 1 };
                e.set_coordinate(bomb, round(bx, by));
                e.set_visual(bomb, self.bomb_looks[side][look]);
                e.set_visible(bomb, true);
            }
            let (dir, impacted, impact) = (plane.dir, plane.impacted, plane.impact);
            if !impacted && f >= impact {
                self.impact(e, index);
            }
            if (f - self.planes[index].launch) % TRAIL_EVERY == 0 {
                self.emit_trail(e, x, y, dir);
            }
        }
    }

    fn update_trails(&mut self, e: &mut Engine) {
        let mut i = 0;
        while i < self.trails.len() {
            let trail = &self.trails[i];
            let age = self.frame - trail.born;
            if age >= trail.lifetime {
                e.set_visible(trail.slot, false);
                self.spare.push(trail.slot);
                self.trails.swap_remove(i);
                continue;
            }
            let t = age as f64;
            let coord = round(trail.x + trail.vx * t, trail.y - trail.vy * t - 0.003 * t * t);
            let visual = self.ember(t / trail.lifetime as f64, 0.25);
            let slot = trail.slot;
            e.set_coordinate(slot, coord);
            e.set_visual(slot, visual);
            e.set_visible(slot, true);
            i += 1;
        }
    }

    fn update_debris(&mut self, e: &mut Engine) {
        let flight = self.config.debris_duration as f64;
        let reassembly = self.config.reassembly_duration;
        let (floor, walls) = (self.floor, self.walls);
        let f = self.frame;
        let planes = &self.planes;
        let piles = &mut self.piles;
        let last_pile = piles.len().saturating_sub(1);
        let pile_of = |x: f64| ((x - walls.0).round().max(0.0) as usize).min(last_pile);
        for piece in &mut self.debris {
            match piece.phase {
                1 => {
                    if f >= piece.homeward {
                        piece.phase = 2;
                        piece.from = (piece.x, piece.y);
                        if let Some(column) = piece.pile.take() {
                            piles[column] = piles[column].saturating_sub(1);
                        }
                    } else {
                        if piece.pile.is_none() {
                            piece.vy -= GRAVITY;
                            piece.x += piece.vx;
                            piece.y += piece.vy;
                            if piece.x < walls.0 || piece.x > walls.1 {
                                piece.x = piece.x.clamp(walls.0, walls.1);
                                piece.vx = -piece.vx * 0.4;
                            }
                            let column = pile_of(piece.x);
                            let ground = floor + piles.get(column).copied().unwrap_or(0) as f64;
                            if piece.y < ground {
                                piece.y = ground;
                                piece.vy = if piece.vy < -0.08 { -piece.vy * 0.3 } else { 0.0 };
                                piece.vx *= 0.55;
                            }
                            if piece.y <= ground {
                                piece.vx *= 0.85;
                                if piece.vy == 0.0 && piece.vx.abs() < 0.05 && !piles.is_empty() {
                                    // come to rest on top of the pile
                                    piece.x = piece.x.round();
                                    piece.y = ground.round();
                                    if piles[column] < PILE_MAX {
                                        piles[column] += 1;
                                    }
                                    piece.pile = Some(column);
                                }
                            }
                        }
                        let age = (f - planes[piece.plane].impact) as f64;
                        let n = piece.cooling.len();
                        let k = ((age / (flight * 0.6)) * (n - 1) as f64).round();
                        let mut k = (k.max(0.0) as usize).min(n - 1);
                        // resting rubble still glows now and then
                        if piece.pile.is_some()
                            && (f / 5 + piece.slot as i64 * 7) % 29 == 0
                            && n > 2
                        {
                            k = k.min(n - 3);
                        }
                        e.set_coordinate(piece.slot, round(piece.x, piece.y));
                        e.set_visual(piece.slot, piece.cooling[k]);
                        continue;
                    }
                }
                2 => {}
                _ => continue,
            }
            // going home: lift out of the rubble and arc into place
            let elapsed = f - piece.homeward;
            if elapsed >= reassembly {
                e.set_coordinate(piece.slot, piece.home);
                e.set_visual(piece.slot, piece.settled);
                piece.phase = 3;
                continue;
            }
            let t = elapsed as f64 / reassembly as f64;
            let eased = if t < 0.5 {
                4.0 * t * t * t
            } else {
                1.0 - (-2.0 * t + 2.0).powi(3) / 2.0
            };
            let (home_x, home_y) = (piece.home.column as f64, piece.home.row as f64);
            let lift = (std::f64::consts::PI * eased).sin() * 2.5;
            let x = piece.from.0 + (home_x - piece.from.0) * eased;
            let y = piece.from.1 + (home_y - piece.from.1) * eased + lift;
            let n = piece.warming.len();
            let k = ((t * (n - 1) as f64).round() as usize).min(n - 1);
            e.set_coordinate(piece.slot, round(x, y));
            e.set_visual(piece.slot, piece.warming[k]);
        }
    }

    fn update_fire(&mut self, e: &mut Engine) {
        for particle in &self.fire {
            let plane = &self.planes[particle.plane];
            let age = self.frame - plane.impact;
            let slot = particle.slot;
            if age < 0 || age >= particle.lifetime {
                e.set_visible(slot, false);
                continue;
            }
            let t = age as f64;
            let coord = round(
                plane.target.column as f64 + particle.vx * t,
                plane.target.row as f64 + particle.vy * t - 0.025 * t * t,
            );
            let visual = self.ember(t / particle.lifetime as f64, 0.2);
            e.set_coordinate(slot, coord);
            e.set_visual(slot, visual);
            e.set_visible(slot, true);
        }
    }

    fn update_rings(&mut self, e: &mut Engine) {
        let radius = self.config.blast_radius as f64 * 0.9;
        for (index, ring) in self.rings.iter().enumerate() {
            let plane = &self.planes[index];
            let age = self.frame - plane.impact;
            if !(0..RING_LIFE).contains(&age) {
                for &slot in ring {
                    e.set_visible(slot, false);
                }
                continue;
            }
            let a = (age + 1) as f64 / RING_LIFE as f64;
            let r = radius * (1.0 - (1.0 - a) * (1.0 - a));
            let n = self.ring_looks.len();
            let color = ((a * n as f64) as usize).min(n - 1);
            let m = ring.len() as f64;
            for (k, &slot) in ring.iter().enumerate() {
                let theta = std::f64::consts::TAU * k as f64 / m;
                let x = plane.target.column as f64 + r * theta.cos();
                let y = plane.target.row as f64 + 0.5 * r * theta.sin();
                // the tangent, folded into 0..180 degrees
                let tangent = (theta.to_degrees() + 90.0).rem_euclid(180.0);
                let look = if !(22.5..157.5).contains(&tangent) {
                    0
                } else if tangent < 67.5 {
                    1
                } else if tangent < 112.5 {
                    2
                } else {
                    3
                };
                e.set_coordinate(slot, round(x, y));
                e.set_visual(slot, self.ring_looks[color][look]);
                e.set_visible(slot, true);
            }
        }
    }

    fn update_smoke(&mut self, e: &mut Engine) {
        for puff in &self.smoke {
            let plane = &self.planes[puff.plane];
            let age = self.frame - plane.impact - puff.delay;
            if age < 0 || age >= puff.lifetime {
                e.set_visible(puff.slot, false);
                continue;
            }
            let t = age as f64;
            let ratio = t / puff.lifetime as f64;
            let x = puff.x + puff.vx * t;
            let y = plane.target.row as f64 + puff.vy * t;
            let stage = ((ratio * 4.0) as usize).min(3);
            e.set_coordinate(puff.slot, round(x, y));
            e.set_visual(puff.slot, self.puffs[stage]);
            e.set_visible(puff.slot, true);
        }
    }

    fn update_flyby(&mut self, e: &mut Engine) {
        let Some(flyby) = self.flyby.as_ref() else {
            return;
        };
        let f = self.frame;
        if f < flyby.start_frame {
            return;
        }
        let age = f - flyby.start_frame;
        let pass = flyby.pass_frames.max(1);
        let in_pass = age <= pass;
        let mut emit_spark: Option<(f64, f64)> = None;

        // 1. Victory jet low pass + post-logo pull-up
        let jet_x = if in_pass {
            let t = age as f64 / pass as f64;
            let x = flyby.start_x + (flyby.end_x - flyby.start_x) * t;
            let climb_u = ((x - flyby.climb_start_x) / (flyby.end_x - flyby.climb_start_x).max(1.0))
                .clamp(0.0, 1.0);
            let y = flyby.base_row + flyby.climb_height * climb_u * climb_u;
            let (column, row) = (x.round() as i64, y.round() as i64);
            for &(slot, offset) in &flyby.parts {
                e.set_coordinate(slot, Coord::new(column + offset.column, row + offset.row));
                e.set_visible(slot, true);
            }
            let flicker = ((f / 2) % 2) as usize;
            e.set_visual(flyby.parts[0].0, self.flames[flicker]);
            e.set_visual(flyby.parts[1].0, self.flames[1 - flicker]);
            if age % 2 == 0 {
                emit_spark = Some((x, y));
            }
            Some(x)
        } else {
            for &(slot, _) in &flyby.parts {
                e.set_visible(slot, false);
            }
            None
        };

        // 2. Contrail underline: ignites behind the jet, glows silver-white, then evaporates
        for cell in &flyby.contrail {
            let c_age = f - cell.ignite_frame;
            if c_age < 0 || c_age >= cell.life {
                e.set_visible(cell.slot, false);
                continue;
            }
            let ratio = c_age as f64 / cell.life as f64;
            let visual = if ratio < 0.06 {
                flyby.contrail_hot[0]
            } else if ratio < 0.13 {
                flyby.contrail_hot[1]
            } else if ratio < 0.20 {
                flyby.contrail_hot[2]
            } else {
                let stages = if cell.outer {
                    &flyby.contrail_outer
                } else {
                    &flyby.contrail_body
                };
                let idx = if ratio < 0.56 {
                    0
                } else if ratio < 0.74 {
                    1
                } else if ratio < 0.89 {
                    2
                } else {
                    3
                };
                stages[idx]
            };
            e.set_coordinate(cell.slot, Coord::new(cell.col, cell.row));
            e.set_visual(cell.slot, visual);
            e.set_visible(cell.slot, true);
        }

        // 3. Jet-wash heat-flare across the logo letters right above the passing jet
        let text_bottom = flyby.text_bottom;
        for glyph in &mut self.logo_glyphs {
            if let Some(jx) = jet_x {
                let d = jx - glyph.home.column as f64;
                if (-1.0..=14.0).contains(&d) {
                    let row_from_bottom = (glyph.home.row - text_bottom).max(0);
                    let level = if d <= 3.5 && row_from_bottom <= 3 {
                        0
                    } else if d <= 8.5 {
                        1
                    } else {
                        2
                    };
                    e.set_visual(glyph.slot, glyph.flare[level]);
                    glyph.flared = true;
                    continue;
                }
            }
            if glyph.flared {
                e.set_visual(glyph.slot, glyph.settled);
                glyph.flared = false;
            }
        }

        // 4. Rising embers drifting off the letters and burning out
        let n_colors = flyby.ember_looks.len().max(1);
        for ember in &flyby.embers {
            let e_age = f - ember.born;
            if e_age < 0 || e_age >= ember.life {
                e.set_visible(ember.slot, false);
                continue;
            }
            let t = e_age as f64;
            let ratio = t / ember.life as f64;
            let sway = (t * 0.14 + ember.sway_phase).sin() * ember.sway_amp * ratio.sqrt();
            let drag = 1.0 - 0.35 * ratio;
            let x = ember.x + ember.vx * t * drag + sway;
            let y = ember.y + ember.vy * t;
            let color_idx = ((ratio * n_colors as f64) as usize).min(n_colors - 1);
            let sym_idx = if ratio < 0.28 {
                0
            } else if ratio < 0.65 {
                1
            } else {
                2
            };
            e.set_coordinate(ember.slot, round(x, y));
            e.set_visual(ember.slot, flyby.ember_looks[color_idx][sym_idx]);
            e.set_visible(ember.slot, true);
        }

        // 5. Short-lived exhaust sparks behind the victory jet
        if let Some((x, y)) = emit_spark {
            let remaining = (self.end_frame - 8 - f).max(1);
            if remaining >= 8 {
                let life = e.rng.randint(12, 24).min(remaining);
                let origin_x = x - 6.0;
                let origin_y = y + e.rng.uniform(-0.2, 0.2);
                let vx = -e.rng.uniform(0.06, 0.16);
                let vy = e.rng.uniform(-0.02, 0.05);
                let slot = match self.spare.pop() {
                    Some(slot) => slot,
                    None => {
                        let slot = e.add_character_sym(self.ember_syms[0], Coord::new(0, 0));
                        e.set_layer(slot, 2);
                        slot
                    }
                };
                self.trails.push(Trail {
                    slot,
                    born: f,
                    x: origin_x,
                    y: origin_y,
                    vx,
                    vy,
                    lifetime: life,
                });
            }
        }
    }

    /// The last frame: everything added hidden, every glyph home.
    fn settle(&mut self, e: &mut Engine) {
        for plane in &self.planes {
            for &(slot, _) in &plane.parts {
                e.set_visible(slot, false);
            }
            e.set_visible(plane.bomb, false);
        }
        if let Some(flyby) = &self.flyby {
            for &(slot, _) in &flyby.parts {
                e.set_visible(slot, false);
            }
            for cell in &flyby.contrail {
                e.set_visible(cell.slot, false);
            }
            for ember in &flyby.embers {
                e.set_visible(ember.slot, false);
            }
        }
        for trail in self.trails.drain(..) {
            e.set_visible(trail.slot, false);
        }
        for slot in self.fire.iter().map(|p| p.slot).chain(self.smoke.iter().map(|p| p.slot)) {
            e.set_visible(slot, false);
        }
        for ring in &self.rings {
            for &slot in ring {
                e.set_visible(slot, false);
            }
        }
        for piece in &mut self.debris {
            e.set_coordinate(piece.slot, piece.home);
            e.set_visual(piece.slot, piece.settled);
            piece.phase = 3;
        }
        for glyph in &mut self.logo_glyphs {
            e.set_coordinate(glyph.slot, glyph.home);
            e.set_visual(glyph.slot, glyph.settled);
            glyph.flared = false;
        }
    }
}

/// The visual `set_appearance` would give `slot` with `sym` in `colors`:
/// under --existing-color-handling always, a character with input colors
/// shows those (and its bold) instead.
pub(crate) fn appearance(e: &mut Engine, slot: u32, sym: Sym, colors: ColorPair) -> Visual {
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
fn plain(e: &mut Engine, sym: Sym, fg: Color) -> Visual {
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

impl Hooks for Airstrike {}

impl Effect for Airstrike {
    fn build(&mut self, e: &mut Engine) -> Result<(), EngineError> {
        let config = self.config.clone();
        let canvas = e.canvas.clone();
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
        let dynamic = e.existing_color_handling() == ExistingColorHandling::Dynamic;
        let characters = e.get_characters(
            CharacterFilter::default(),
            CharacterSort::TopToBottomLeftToRight,
        );
        let space = e.sym(" ");
        let solid: Vec<u32> = characters
            .iter()
            .copied()
            .filter(|&s| e.input_sym(s) != space)
            .collect();
        let speed = config.flight_speed;
        let fire_colors = &config.fire_colors;
        let hottest = fire_colors[0];
        let soot = Color::from_hex(SOOT).expect("soot color");

        // looks
        self.ember_syms = EMBER_SYMBOLS.map(|s| e.sym(s));
        let ember_syms = self.ember_syms;
        self.embers = fire_colors
            .iter()
            .map(|&color| ember_syms.map(|sym| plain(e, sym, color)))
            .collect();
        let smoke_colors = SMOKE_COLORS.map(|c| Color::from_hex(c).expect("smoke color"));
        for (k, look) in self.puffs.iter_mut().enumerate() {
            let sym = e.sym(SMOKE_SYMBOLS[k]);
            *look = plain(e, sym, smoke_colors[k]);
        }
        let ring_syms = ["-", "/", "|", "\\"].map(|s| e.sym(s));
        self.ring_looks = fire_colors
            .iter()
            .map(|&color| ring_syms.map(|sym| plain(e, sym, color)))
            .collect();
        let bomb_syms = [["-", "\\", "|"], ["-", "/", "|"]];
        for side in 0..2 {
            for look in 0..3 {
                let sym = e.sym(bomb_syms[side][look]);
                self.bomb_looks[side][look] = plain(e, sym, config.plane_color);
            }
        }
        let dash = e.sym("-");
        let flame_syms = [e.sym("~"), dash];
        let flame_colors = [hottest, fire_colors[1.min(fire_colors.len() - 1)]];
        self.flames = [
            plain(e, flame_syms[0], flame_colors[0]),
            plain(e, flame_syms[1], flame_colors[1]),
        ];

        // the arena: rubble settles on a line under the text, inside the canvas
        let (left, right) = (canvas.text_left, canvas.text_right);
        let (bottom, top) = (canvas.text_bottom, canvas.text_top);
        self.floor = (bottom - 2).max(canvas.bottom).min(bottom) as f64;
        let reach = config.blast_radius;
        let wall_left = left.saturating_sub(reach).max(canvas.left);
        let wall_right = right.saturating_add(reach).min(canvas.right).max(wall_left);
        self.walls = (wall_left as f64, wall_right as f64);
        self.piles = vec![0; (wall_right - wall_left).min(100_000) as usize + 1];

        // the targets: spread across the text, struck in a seeded order,
        // snapped to the nearest glyph (rows weigh 4x: cells are twice as
        // tall as wide)
        let width = (right - left).max(0) as f64;
        let count = config.plane_count;
        let mut columns: Vec<i64> = (0..count).collect();
        e.rng.shuffle(&mut columns);
        for index in 0..count {
            let fraction = (columns[index as usize] as f64 + 0.5) / count as f64;
            let rough = Coord::new(
                left + (width * fraction).round() as i64,
                e.rng.randint(bottom.min(top), top.max(bottom)),
            );
            let target = solid
                .iter()
                .map(|&s| e.input_coord(s))
                .min_by_key(|c| {
                    let (dx, dy) = (c.column - rough.column, c.row - rough.row);
                    dx.saturating_mul(dx)
                        .saturating_add(dy.saturating_mul(dy).saturating_mul(4))
                })
                .unwrap_or(rough);

            let from_left = index % 2 == 0;
            let dir = if from_left { 1.0 } else { -1.0 };
            let low = (top + 2).min(canvas.top.max(top)) as f64;
            let high = ((top + 5 + index % 3).min(canvas.top - 1) as f64).max(low);
            let drop = (low - 1.0 - target.row as f64).max(0.0);
            let fall = ((drop + 1.0).sqrt() * 8.0).round().clamp(10.0, 36.0);
            let release_x = target.column as f64 - dir * speed * fall;
            let edge = if from_left {
                canvas.left as f64 - 8.0
            } else {
                canvas.right as f64 + 8.0
            };
            let start_x = if from_left {
                edge.min(release_x - 4.0)
            } else {
                edge.max(release_x + 4.0)
            };
            let far_edge = if from_left {
                canvas.right as f64 + 8.0
            } else {
                canvas.left as f64 - 8.0
            };
            let launch = index.saturating_mul(config.launch_delay);
            // f64 -> i64 saturates
            let release = launch.saturating_add(((release_x - start_x).abs() / speed).ceil() as i64);
            let impact = release.saturating_add(fall as i64);
            let away = (far_edge - release_x).abs();
            let a = AFTERBURNER;
            let exit_t = ((-speed + (speed * speed + 4.0 * a * away).sqrt()) / (2.0 * a)).ceil();
            let exit = release.saturating_add(exit_t as i64).max(impact);

            let mut parts = Vec::with_capacity(JET.len());
            for (symbol, dx, dy) in JET {
                let symbol = if from_left {
                    symbol
                } else {
                    match symbol {
                        ">" => "<",
                        "[" => "]",
                        "\\" => "/",
                        "/" => "\\",
                        s => s,
                    }
                };
                let sym = e.sym(symbol);
                let slot = e.add_character_sym(sym, Coord::new(0, 0));
                e.set_layer(slot, 3);
                let visual = plain(e, sym, config.plane_color);
                e.set_visual(slot, visual);
                let dx = if from_left { dx } else { -dx };
                parts.push((slot, Coord::new(dx, dy)));
            }
            let bomb = e.add_character_sym(dash, Coord::new(0, 0));
            e.set_layer(bomb, 3);
            self.planes.push(Plane {
                parts,
                bomb,
                dir,
                start_x,
                release_x,
                high,
                low,
                target,
                launch,
                release,
                impact,
                exit,
                fall,
                drop,
                impacted: false,
            });
        }

        // the text: shown settled from the start; glyphs in a blast radius of
        // their nearest bomb become its debris
        let cooling_colors = {
            let mut stops = fire_colors.clone();
            stops.push(soot);
            ramp(&stops, RAMP)
        };
        let radius_sq = config.blast_radius.saturating_mul(config.blast_radius);
        let dist_sq = |a: Coord, b: Coord| {
            let (dx, dy) = (a.column - b.column, a.row - b.row);
            dx.saturating_mul(dx)
                .saturating_add(dy.saturating_mul(dy).saturating_mul(4))
        };
        for &slot in &characters {
            let home = e.input_coord(slot);
            let sym = e.input_sym(slot);
            let colors = if dynamic {
                ColorPair::new(e.input_fg(slot), e.input_bg(slot))
            } else {
                let fg = mapping
                    .as_ref()
                    .and_then(|m| m.get(&home).copied())
                    .unwrap_or(fallback);
                ColorPair::new(Some(fg), None)
            };
            let settled = appearance(e, slot, sym, colors);
            e.set_visual(slot, settled);
            e.set_visible(slot, true);
            if sym == space {
                continue;
            }
            let base_fg = colors.fg_color.unwrap_or(fallback);
            let warm_mid = fire_colors[1.min(fire_colors.len() - 1)];
            let hot_bg = if colors.bg_color.is_none()
                && e.existing_color_handling() != ExistingColorHandling::Always
                && home.row <= bottom + 1
            {
                Some(Color::from_rgb(44, 18, 0))
            } else {
                colors.bg_color
            };
            let flare = [
                appearance(
                    e,
                    slot,
                    sym,
                    ColorPair::new(Some(mix(base_fg, hottest, 0.72)), hot_bg),
                ),
                appearance(
                    e,
                    slot,
                    sym,
                    ColorPair::new(Some(mix(base_fg, warm_mid, 0.45)), colors.bg_color),
                ),
                appearance(
                    e,
                    slot,
                    sym,
                    ColorPair::new(Some(mix(base_fg, warm_mid, 0.2)), colors.bg_color),
                ),
            ];
            self.logo_glyphs.push(LogoGlyph {
                slot,
                home,
                settled,
                flare,
                flared: false,
            });
            let nearest = self
                .planes
                .iter()
                .enumerate()
                .min_by_key(|(_, p)| dist_sq(home, p.target));
            let Some((plane, p)) = nearest else { continue };
            if dist_sq(home, p.target) > radius_sq {
                continue;
            }
            let cooling = cooling_colors
                .iter()
                .map(|&c| appearance(e, slot, sym, ColorPair::new(Some(c), None)))
                .collect();
            let mut warming: Vec<Visual> = (0..RAMP - 1)
                .map(|k| {
                    let t = k as f64 / (RAMP - 1) as f64;
                    let color = match colors.fg_color {
                        Some(fg) => mix(soot, fg, t),
                        None => soot,
                    };
                    if colors.fg_color.is_none() && t >= 0.5 {
                        settled
                    } else {
                        appearance(e, slot, sym, ColorPair::new(Some(color), colors.bg_color))
                    }
                })
                .collect();
            warming.push(settled);
            self.debris.push(Debris {
                slot,
                home,
                plane,
                x: home.column as f64,
                y: home.row as f64,
                vx: 0.0,
                vy: 0.0,
                homeward: i64::MAX,
                from: (0.0, 0.0),
                cooling,
                warming,
                settled,
                phase: 0,
                pile: None,
            });
        }

        // the fire, shockwave and smoke: made up front, hidden until the hit
        let mut longest_fire = 0;
        let ring_points = config.blast_radius.saturating_mul(3).clamp(16, 120);
        for plane in 0..self.planes.len() {
            let target = self.planes[plane].target;
            for _ in 0..config.fire_particles {
                let slot = e.add_character_sym(ember_syms[0], target);
                e.set_layer(slot, 4);
                let angle = e.rng.uniform(0.0, std::f64::consts::TAU);
                let speed = e.rng.uniform(0.18, 1.10);
                let lifetime = e.rng.randint(FIRE_LIFE.0, FIRE_LIFE.1);
                longest_fire = longest_fire.max(lifetime);
                self.fire.push(Fire {
                    slot,
                    plane,
                    vx: angle.cos() * speed,
                    vy: angle.sin() * speed * 0.6 + 0.35,
                    lifetime,
                });
            }
            let ring = (0..ring_points)
                .map(|_| {
                    let slot = e.add_character_sym(ring_syms[0], target);
                    e.set_layer(slot, 4);
                    slot
                })
                .collect();
            self.rings.push(ring);
            for _ in 0..SMOKE_PUFFS {
                let slot = e.add_character_sym(ember_syms[2], target);
                e.set_layer(slot, 1);
                self.smoke.push(Smoke {
                    slot,
                    plane,
                    delay: e.rng.randint(SMOKE_DELAY.0, SMOKE_DELAY.1),
                    x: target.column as f64 + e.rng.uniform(-4.0, 4.0),
                    vx: e.rng.uniform(-0.03, 0.06),
                    vy: e.rng.uniform(0.05, 0.11),
                    lifetime: e.rng.randint(SMOKE_LIFE.0, SMOKE_LIFE.1),
                });
            }
        }

        // the end: the last glyph home, the last jet (and its trail) gone,
        // the last fire, ring and smoke burnt out; then the hold
        let homecoming = (config.debris_duration / 3)
            .saturating_add(config.debris_duration)
            .saturating_add(config.reassembly_duration);
        let burn = longest_fire
            .max(RING_LIFE)
            .max(SMOKE_DELAY.1 + SMOKE_LIFE.1);
        let last = self
            .planes
            .iter()
            .map(|p| {
                p.impact
                    .saturating_add(homecoming.max(burn))
                    .max(p.exit.saturating_add(TRAIL_LIFE.1))
            })
            .max()
            .unwrap_or(0);
        let flourish_len = config.final_hold_time;
        self.end_frame = last.saturating_add(flourish_len);

        // victory flyby flourish: a final jet streaks low beneath the restored logo,
        // leaving a glowing contrail underline while embers lift off the letters
        if flourish_len >= 24 && !solid.is_empty() {
            let start_frame = last;
            let pass_frames = ((flourish_len as f64) * 0.42)
                .round()
                .clamp(16.0, 150.0) as i64;
            let start_x = canvas.left as f64 - 8.0;
            let end_x = canvas.right as f64 + 10.0;
            let contrail_row = if bottom - canvas.bottom >= 3 {
                bottom - 2
            } else if bottom - canvas.bottom >= 1 {
                bottom - 1
            } else {
                canvas.bottom
            };
            let base_row = contrail_row as f64;
            let climb_start_x = (right as f64 + 6.0).min(end_x - 2.0);
            let climb_height = ((canvas.top - contrail_row) as f64 * 0.45).clamp(0.0, 10.0);

            let victory_plane_color = mix(config.plane_color, Color::from_rgb(255, 255, 255), 0.25);
            let mut parts = Vec::with_capacity(JET.len() + 1);
            // twin afterburner flame slots at (-6, 0) and (-5, 0)
            let flame_outer = e.add_character_sym(flame_syms[1], Coord::new(0, 0));
            e.set_layer(flame_outer, 3);
            e.set_visual(flame_outer, self.flames[1]);
            parts.push((flame_outer, Coord::new(-6, 0)));
            for (symbol, dx, dy) in JET {
                let sym = e.sym(symbol);
                let slot = e.add_character_sym(sym, Coord::new(0, 0));
                e.set_layer(slot, 3);
                let visual = plain(e, sym, victory_plane_color);
                e.set_visual(slot, visual);
                parts.push((slot, Coord::new(dx, dy)));
            }

            let sym_hot_hi = e.sym("▃");
            let sym_body_hi = e.sym("▂");
            let sym_thin = e.sym("▁");
            let sym_shade = e.sym("░");
            let sym_dot = e.sym("·");
            let warm_mid = fire_colors[1.min(fire_colors.len() - 1)];
            let warm_cool = fire_colors[2.min(fire_colors.len() - 1)];
            let contrail_hot = [
                plain(e, sym_hot_hi, hottest),
                plain(e, sym_body_hi, warm_mid),
                plain(e, sym_body_hi, mix(warm_cool, config.plane_color, 0.35)),
            ];
            let contrail_body = [
                plain(
                    e,
                    sym_body_hi,
                    mix(config.plane_color, Color::from_rgb(245, 250, 255), 0.65),
                ),
                plain(e, sym_thin, config.plane_color),
                plain(
                    e,
                    sym_shade,
                    mix(config.plane_color, Color::from_rgb(45, 50, 58), 0.55),
                ),
                plain(e, sym_dot, Color::from_rgb(65, 72, 82)),
            ];
            let contrail_outer = [
                plain(
                    e,
                    sym_thin,
                    mix(config.plane_color, Color::from_rgb(225, 235, 248), 0.35),
                ),
                plain(
                    e,
                    sym_shade,
                    mix(config.plane_color, Color::from_rgb(55, 62, 72), 0.45),
                ),
                plain(e, sym_dot, Color::from_rgb(70, 78, 88)),
                plain(e, sym_dot, Color::from_rgb(45, 50, 58)),
            ];

            let margin = ((canvas.right - canvas.left - (right - left)).max(0) / 10).clamp(2, 12);
            let span_left = left.saturating_sub(margin).max(canvas.left);
            let span_right = right.saturating_add(margin).min(canvas.right).max(span_left);
            let span_len = (span_right - span_left + 1).max(1);
            let step = ((span_len + 511) / 512).max(1) as usize;
            let mut contrail = Vec::new();
            let contrail_deadline = self.end_frame.saturating_sub(16);
            for col in (span_left..=span_right).step_by(step) {
                let exhaust_x = col as f64 + 4.0;
                let col_t = ((exhaust_x - start_x) / (end_x - start_x).max(1.0)).clamp(0.0, 1.0);
                let ignite_frame = start_frame + (col_t * pass_frames as f64).round() as i64;
                let outer = col < left || col > right;
                let budget = (contrail_deadline - ignite_frame).max(10);
                let edge_trim = if outer {
                    (budget as f64 * 0.22) as i64
                } else {
                    0
                };
                let jitter = e.rng.randint(-14, 14);
                let life = (budget - edge_trim + jitter).clamp(10, budget);
                let slot = e.add_character_sym(sym_body_hi, Coord::new(col, contrail_row));
                e.set_layer(slot, 2);
                contrail.push(ContrailCell {
                    slot,
                    col,
                    row: contrail_row,
                    ignite_frame,
                    life,
                    outer,
                });
            }

            let sym_star = e.sym("*");
            let sym_quad = e.sym("▖");
            let ember_looks: Vec<[Visual; 3]> = fire_colors
                .iter()
                .map(|&color| {
                    [
                        plain(e, sym_star, color),
                        plain(e, sym_quad, color),
                        plain(e, sym_dot, color),
                    ]
                })
                .collect();

            let mut sources = solid.clone();
            e.rng.shuffle(&mut sources);
            let ember_count = sources.len().min(72);
            let ember_deadline = self.end_frame.saturating_sub(12);
            let mut embers = Vec::with_capacity(ember_count);
            for (idx, &src_slot) in sources[..ember_count].iter().enumerate() {
                let c = e.input_coord(src_slot);
                let col_t = ((c.column as f64 - start_x) / (end_x - start_x).max(1.0))
                    .clamp(0.0, 1.0);
                let jet_pass = start_frame + (col_t * pass_frames as f64).round() as i64;
                // Wave 1 kicks off right in the jet's wake; wave 2 lifts off while the contrail glows
                let delay = if idx % 2 == 0 {
                    e.rng.randint(1, 20)
                } else {
                    e.rng.randint(22, 82)
                };
                let born = (jet_pass + delay)
                    .min(ember_deadline.saturating_sub(10))
                    .max(start_frame);
                let avail = (ember_deadline - born).max(10);
                let life = e.rng.randint(60, 125).min(avail).max(10);
                let slot = e.add_character_sym(sym_star, c);
                e.set_layer(slot, 4);
                embers.push(FlourishEmber {
                    slot,
                    born,
                    life,
                    x: c.column as f64,
                    y: c.row as f64 + 0.5,
                    vx: e.rng.uniform(0.025, 0.095),
                    vy: e.rng.uniform(0.065, 0.145),
                    sway_phase: e.rng.uniform(0.0, std::f64::consts::TAU),
                    sway_amp: e.rng.uniform(0.45, 1.4),
                });
            }

            self.flyby = Some(VictoryFlyby {
                parts,
                start_frame,
                pass_frames,
                start_x,
                end_x,
                base_row,
                text_bottom: bottom,
                climb_start_x,
                climb_height,
                contrail,
                embers,
                contrail_hot,
                contrail_body,
                contrail_outer,
                ember_looks,
            });
        }

        self.frame = 0;
        Ok(())
    }

    fn next_frame(&mut self, e: &mut Engine) -> bool {
        if self.frame > self.end_frame {
            return false;
        }
        if self.frame == self.end_frame {
            self.settle(e);
        } else {
            self.update_planes(e);
            self.update_flyby(e);
            self.update_trails(e);
            self.update_debris(e);
            self.update_fire(e);
            self.update_rings(e);
            self.update_smoke(e);
        }
        self.frame += 1;
        true
    }
}



#[cfg(test)]
pub(crate) mod tests {
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

    const CAP: u64 = 20_000;

    fn args<'a>(globals: &[&'a str], effect: &[&'a str]) -> Vec<&'a str> {
        let mut all = globals.to_vec();
        all.push("airstrike");
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
                "300",
                "--canvas-height",
                "90",
            ],
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
                let a = args(canvas, &["--launch-delay", "5", "--flight-speed", "3"]);
                if let Some(run) = try_run(input, &a, CAP) {
                    assert_settled(&run, input, &a);
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
    fn deterministic_for_a_seed() {
        let input = "OMARCHY\nhello world\n";
        let a = args(&["--seed", "9"], &["--launch-delay", "4"]);
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
            ("--plane-count", "9"),
            ("--flight-speed", "0.2"),
            ("--launch-delay", "120"),
            ("--debris-duration", "120"),
            ("--reassembly-duration", "240"),
            ("--final-hold-time", "5"),
        ] {
            let frames = run(input, &args(&["--seed", "4"], &[option, value]), CAP).frames;
            assert_ne!(
                frames, base,
                "{option} {value} left the run length at {base}"
            );
        }
        // short timings: the fire's lifetime still bounds the run
        let short = &[
            "--debris-duration",
            "1",
            "--reassembly-duration",
            "1",
            "--final-hold-time",
            "0",
        ];
        let a = args(&["--seed", "4"], short);
        let run = run(input, &a, CAP);
        assert_settled(&run, input, &a);
    }
}
