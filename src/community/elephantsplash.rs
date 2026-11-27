//! elephantsplash: a playful elephant walks in, drinks from a puddle and
//! sprays water that splashes the text into place.
//!
//! Original effect by Tushar Malpani (@tusharmalpani20),
//! https://github.com/tusharmalpani20/tte-community-effects, MIT.
//! (Python TerminalTextEffects plugin `effect_elephant_splash.py`,
//! ChrisBuilds/terminaltexteffects#75.) The full elephant is adapted from
//! ASCII artwork by jgs (asciiart.website/art/4937); the signature is omitted.
//!
//! The story: the text starts out dry, a dim outline of itself. The elephant
//! (one rigid sprite: a grid of added characters sharing an integer origin,
//! redrawn from fixed ASCII poses) is already peeking in from the left on the
//! first frame and walks (a new leg pose every `--walk-pose-frames`, a step
//! every `--horizontal-step-frames`) to a spot where it faces the text: under
//! it when the canvas is tall enough, beside it when wide enough, otherwise
//! at the left edge behind the text. It settles, lowers its trunk and drinks
//! the rippling puddle (72 frames) while bubbles climb the trunk, raises the
//! trunk (30 frames) and sweeps a spray of droplets across the text along
//! high arcs. Every droplet lands on its own patch of the text, planned at
//! build so the patches cover every character, and the water spreads out
//! from the impact as a ripple: `*` then `.` in the water colors, then the
//! symbol cooling from water to the final gradient (or, with
//! `--existing-color-handling dynamic`, the input colors). Wet text is drawn
//! in front of the elephant. It waves its trunk for 120 frames, lowers it,
//! walks off to the right, and the freshly drenched text drips beads of water
//! from the undersides of the letters into a rippling puddle beneath it before
//! evaporating cleanly over `--final-hold-frames`.
//!
//! Walks take at most 60 steps (longer distances take wider steps), so the
//! run length does not balloon on wide canvases. Canvases under 41x16 use a
//! compact elephant; under 12x6 there is no sprite, just the original's
//! splash and 12 radial reveal bands.
//!
//! `--movement-speed` is a no-op in the original ("retained for
//! compatibility"); here it scales the droplet flight speed, with the
//! default (0.35) giving the original's 1.6 cells per frame.

use clap::Args;

use crate::cli::parse_color;
use crate::effects::common::{
    parse_gradient_direction, parse_gradient_steps, parse_non_negative_int, parse_positive_float,
    parse_positive_int,
};
use crate::engine::animation::{Animation, ExistingColorHandling};
use crate::engine::error::EngineError;
use crate::engine::terminal::{CharacterFilter, CharacterSort};
use crate::fx::run::Effect;
use crate::fx::{Engine, Hooks, Name, Sym, NONE};
use crate::utils::easing::Easing;
use crate::utils::geometry::Coord;
use crate::utils::graphics::{Color, ColorPair, Gradient, GradientDirection};
use crate::utils::pycompat::round_half_even;

#[derive(Args, Debug, Clone)]
pub struct ElephantSplashConfig {
    /// Primary color of the elephant.
    #[arg(long = "elephant-color", default_value = "8B5CF6", value_parser = parse_color)]
    pub elephant_color: Color,

    /// Highlight color used for the elephant's ears, eye, and smile.
    #[arg(long = "elephant-highlight-color", default_value = "C4B5FD", value_parser = parse_color)]
    pub elephant_highlight_color: Color,

    /// Colors used for the water droplets and splash reveal.
    #[arg(long = "water-colors", num_args = 1.., value_parser = parse_color,
          default_values = ["38BDF8", "7DD3FC", "E0F2FE"])]
    pub water_colors: Vec<Color>,

    /// Speed of the sprayed droplets (0.35 is the original's pace). The
    /// original keeps this option for compatibility only.
    #[arg(long = "movement-speed", default_value_t = 0.35, value_parser = parse_positive_float)]
    pub movement_speed: f64,

    /// Number of frames to hold each walking pose.
    #[arg(long = "walk-pose-frames", default_value_t = 8, value_parser = parse_positive_int)]
    pub walk_pose_frames: i64,

    /// Number of frames between one-column elephant steps.
    #[arg(long = "horizontal-step-frames", default_value_t = 4, value_parser = parse_positive_int)]
    pub horizontal_step_frames: i64,

    /// Space separated, unquoted, list of colors for the character gradient.
    #[arg(long = "final-gradient-stops", num_args = 1.., value_parser = parse_color,
          default_values = ["8B5CF6", "C4B5FD", "F5F3FF"])]
    pub final_gradient_stops: Vec<Color>,

    /// Number of gradient steps to use.
    #[arg(long = "final-gradient-steps", num_args = 1.., value_parser = parse_gradient_steps,
          default_values = ["12"])]
    pub final_gradient_steps: Vec<i64>,

    /// Number of frames to display each gradient step.
    #[arg(long = "final-gradient-frames", default_value_t = 4, value_parser = parse_positive_int)]
    pub final_gradient_frames: i64,

    /// Direction of the final gradient.
    #[arg(long = "final-gradient-direction", default_value = "radial",
          value_parser = parse_gradient_direction)]
    pub final_gradient_direction: GradientDirection,

    /// Number of frames to hold the completed branding (with the dripping-puddle flourish). Zero still emits one clean final frame.
    #[arg(long = "final-hold-frames", default_value_t = 420, value_parser = parse_non_negative_int)]
    pub final_hold_frames: i64,
}

// ------------------------------------------------------------------ poses

const WALK_1: usize = 0;
const DRINK_1: usize = 4;
const RAISE_1: usize = 7;
const SPRAY_1: usize = 10;
const WALK_POSES: i64 = 4;

const DRINK_FRAMES: i64 = 72;
const CELEBRATE_FRAMES: i64 = 120;
const RAISE_FRAMES: i64 = 30;
const SETTLE_FRAMES: i64 = 8;
const REVEAL_BANDS: usize = 12;
const DROPLET_SPEED: f64 = 1.6;
const DEFAULT_MOVEMENT_SPEED: f64 = 0.35;
/// Frame durations are u32 in the engine (and summed per scene).
const MAX_FRAME_DURATION: i64 = 1 << 24;

// Pose tables generated from the original's padded FULL_POSES / COMPACT_POSES
// (walk_1..4, drink_1..3, raise_1..3, spray_1; spray_2 and the wiggle poses
// are identical to spray_1 and unused) and their trunk-tip rows.
const FULL_WIDTH: usize = 41;
const FULL_HEIGHT: usize = 16;
static FULL_POSES: [[&str; 16]; 11] = [
    // walk_1
    [
        r#"                                         "#,
        r#"                                         "#,
        r#"                                         "#,
        r#"                  .-""-.-""""-.          "#,
        r#"                 /'     \      \         "#,
        r#"         .-""""-/       (       '-.      "#,
        r#"       .'       |        ;    e    \     "#,
        r#"      /          \       |     __.  |    "#,
        r#"     /            '._     ;   .-'   |    "#,
        r#"    //|              \     \,-'     |    "#,
        r#"   // |               `;.___>   \   |    "#,
        r#" /`|  /                |`\       \  |    "#,
        r#" |/  /     _,.-----\   |  \       | |    "#,
        r#"    /    .;   |    |   |   \      | |    "#,
        r#"   |    / |   \    /   |\__/      \_)    "#,
        r#"    \__/  \___/    \___/                 "#,
    ],
    // walk_2
    [
        r#"                                         "#,
        r#"                                         "#,
        r#"                                         "#,
        r#"                  .-""-.-""""-.          "#,
        r#"                 /'     \      \         "#,
        r#"         .-""""-/       (       '-.      "#,
        r#"       .'       |        ;    e    \     "#,
        r#"      /          \       |     __.  |    "#,
        r#"     /            '._     ;   .-'   |    "#,
        r#"    //|              \     \,-'     |    "#,
        r#"   // |               `;.___>   \   |    "#,
        r#" /`|  /                |`\       \  |    "#,
        r#" |/  /     _,.-----\   |  \       | |    "#,
        r#"   /     .;   |    |   |   \      | |    "#,
        r#"  /     / |   \    /   |\__/      \_)    "#,
        r#"   \___/  \___/    \___/                 "#,
    ],
    // walk_3
    [
        r#"                                         "#,
        r#"                                         "#,
        r#"                                         "#,
        r#"                  .-""-.-""""-.          "#,
        r#"                 /'     \      \         "#,
        r#"         .-""""-/       (       '-.      "#,
        r#"       .'       |        ;    e    \     "#,
        r#"      /          \       |     __.  |    "#,
        r#"     /            '._     ;   .-'   |    "#,
        r#"    //|              \     \,-'     |    "#,
        r#"   // |               `;.___>   \   |    "#,
        r#" /`|  /                |`\       \  |    "#,
        r#" |/  /     _,.-----\   |  \       | |    "#,
        r#"    /   .;    |   |   |   \       | |    "#,
        r#"   |   /  |   \   /    |\__/      \_)    "#,
        r#"   \___/   \___/   \___/                 "#,
    ],
    // walk_4
    [
        r#"                                         "#,
        r#"                                         "#,
        r#"                                         "#,
        r#"                  .-""-.-""""-.          "#,
        r#"                 /'     \      \         "#,
        r#"         .-""""-/       (       '-.      "#,
        r#"       .'       |        ;    e    \     "#,
        r#"      /          \       |     __.  |    "#,
        r#"     /            '._     ;   .-'   |    "#,
        r#"    //|              \     \,-'     |    "#,
        r#"   // |               `;.___>   \   |    "#,
        r#" /`|  /                |`\       \  |    "#,
        r#" |/  /     _,.-----\   |  \       | |    "#,
        r#"    /    .;   |    |    |  \      | |    "#,
        r#"   |    / |   \    /    \__/      \_)    "#,
        r#"    \__/  \___/     \__/                 "#,
    ],
    // drink_1
    [
        r#"                                         "#,
        r#"                                         "#,
        r#"                                         "#,
        r#"                  .-""-.-""""-.          "#,
        r#"                 /'     \      \         "#,
        r#"         .-""""-/       (       '-.      "#,
        r#"       .'       |        ;    e    \     "#,
        r#"      /          \       |     __.  |    "#,
        r#"     /            '._     ;   .-'   |    "#,
        r#"    //|              \     \,-'     |    "#,
        r#"   // |               `;.___>   \   |    "#,
        r#" /`|  /                |`\       \  |    "#,
        r#" |/  /     _,.-----\   |  \       | |    "#,
        r#"    /    .;   |    |   |   \      | |    "#,
        r#"   |    / |   \    /   |\__/      \_)    "#,
        r#"    \__/  \___/    \___/                 "#,
    ],
    // drink_2
    [
        r#"                                         "#,
        r#"                                         "#,
        r#"                                         "#,
        r#"                  .-""-.-""""-.          "#,
        r#"                 /'     \      \         "#,
        r#"         .-""""-/       (       '-.      "#,
        r#"       .'       |        ;    e    \     "#,
        r#"      /          \       |     __.  |    "#,
        r#"     /            '._     ;   .-'   |    "#,
        r#"    //|              \     \,-'     |    "#,
        r#"   // |               `;.___>   \   |    "#,
        r#" /`|  /                |`\       \  |    "#,
        r#" |/  /     _,.-----\   |  \       | |    "#,
        r#"    /    .;   |    |   |   \      | |    "#,
        r#"   |    / |   \    /   |\__/      \ |    "#,
        r#"    \__/  \___/    \___/                 "#,
    ],
    // drink_3
    [
        r#"                                         "#,
        r#"                                         "#,
        r#"                                         "#,
        r#"                  .-""-.-""""-.          "#,
        r#"                 /'     \      \         "#,
        r#"         .-""""-/       (       '-.      "#,
        r#"       .'       |        ;    e    \     "#,
        r#"      /          \       |     __.  |    "#,
        r#"     /            '._     ;   .-'   |    "#,
        r#"    //|              \     \,-'     |    "#,
        r#"   // |               `;.___>   \   |    "#,
        r#" /`|  /                |`\       \  |    "#,
        r#" |/  /     _,.-----\   |  \       | |    "#,
        r#"    /    .;   |    |   |   \      | |    "#,
        r#"   |    / |   \    /   |\__/      | |    "#,
        r#"    \__/  \___/    \___/          \_)    "#,
    ],
    // raise_1
    [
        r#"                                         "#,
        r#"                                         "#,
        r#"                                         "#,
        r#"                  .-""-.-""""-.          "#,
        r#"                 /'     \      \         "#,
        r#"         .-""""-/       (       '-.      "#,
        r#"       .'       |        ;    e    \     "#,
        r#"      /          \       |     __.  |    "#,
        r#"     /            '._     ;   .-'   |    "#,
        r#"    //|              \     \,-'     |    "#,
        r#"   // |               `;.___>   \   |    "#,
        r#" /`|  /                |`\       \  |    "#,
        r#" |/  /     _,.-----\   |  \       | |    "#,
        r#"    /    .;   |    |   |   \      | |    "#,
        r#"   |    / |   \    /   |\__/      | |    "#,
        r#"    \__/  \___/    \___/          \_)    "#,
    ],
    // raise_2
    [
        r#"                                         "#,
        r#"                                         "#,
        r#"                                     .-~ "#,
        r#"                  .-""-.-""""-.      / ; "#,
        r#"                 /'     \      \    / /  "#,
        r#"         .-""""-/       (       '--' /   "#,
        r#"       .'       |        ;    e     /    "#,
        r#"      /          \       |      __.'     "#,
        r#"     /            '._     ;    .-'       "#,
        r#"    //|              \     \,-'          "#,
        r#"   // |               `;.___>            "#,
        r#" /`|  /                |`\               "#,
        r#" |/  /     _,.-----\   |  \              "#,
        r#"    /    .;   |    |   |   \             "#,
        r#"   |    / |   \    /   |\__/             "#,
        r#"    \__/  \___/    \___/                 "#,
    ],
    // raise_3
    [
        r#"                                       _ "#,
        r#"                                      / )"#,
        r#"                                     ; | "#,
        r#"                  .-""-.-""""-.      | ; "#,
        r#"                 /'     \      \    / /  "#,
        r#"         .-""""-/       (       '--' /   "#,
        r#"       .'       |        ;    e     /    "#,
        r#"      /          \       |      __.'     "#,
        r#"     /            '._     ;    .-'       "#,
        r#"    //|              \     \,-'          "#,
        r#"   // |               `;.___>            "#,
        r#" /`|  /                |`\               "#,
        r#" |/  /     _,.-----\   |  \              "#,
        r#"    /    .;   |    |   |   \             "#,
        r#"   |    / |   \    /   |\__/             "#,
        r#"    \__/  \___/    \___/                 "#,
    ],
    // spray_1
    [
        r#"                                       _ "#,
        r#"                                      / )"#,
        r#"                                     ; | "#,
        r#"                  .-""-.-""""-.      | ; "#,
        r#"                 /'     \      \    / /  "#,
        r#"         .-""""-/       (       '--' /   "#,
        r#"       .'       |        ;    e     /    "#,
        r#"      /          \       |      __.'     "#,
        r#"     /            '._     ;    .-'       "#,
        r#"    //|              \     \,-'          "#,
        r#"   // |               `;.___>            "#,
        r#" /`|  /                |`\               "#,
        r#" |/  /     _,.-----\   |  \              "#,
        r#"    /    .;   |    |   |   \             "#,
        r#"   |    / |   \    /   |\__/             "#,
        r#"    \__/  \___/    \___/                 "#,
    ],
];
static FULL_TIP_ROWS: [usize; 11] = [14, 14, 14, 14, 14, 15, 15, 15, 2, 0, 0];
const COMPACT_WIDTH: usize = 12;
const COMPACT_HEIGHT: usize = 5;
static COMPACT_POSES: [[&str; 5]; 11] = [
    // walk_1
    [
        r#"   __       "#,
        r#" /'  '-.    "#,
        r#"| (o)  |__  "#,
        r#" \   /  ')  "#,
        r#"  /_\ /_\   "#,
    ],
    // walk_2
    [
        r#"   __       "#,
        r#" /'  '-.    "#,
        r#"| (o)  |__  "#,
        r#" \   /  ')  "#,
        r#"  _/\ /_\   "#,
    ],
    // walk_3
    [
        r#"   __       "#,
        r#" /'  '-.    "#,
        r#"| (o)  |__  "#,
        r#" \   /  ')  "#,
        r#"  /_\ _/\   "#,
    ],
    // walk_4
    [
        r#"   __       "#,
        r#" /'  '-.    "#,
        r#"| (o)  |__  "#,
        r#" \   /  ')  "#,
        r#"  _/\ _/\   "#,
    ],
    // drink_1
    [
        r#"   __       "#,
        r#" /'  '-.    "#,
        r#"| (o)    \  "#,
        r#" \    __ \  "#,
        r#"  /_\ /_\ \~"#,
    ],
    // drink_2
    [
        r#"   __       "#,
        r#" /'  '-.    "#,
        r#"| (o)    \  "#,
        r#" \    __ \  "#,
        r#"  /_\ /_\ \o"#,
    ],
    // drink_3
    [
        r#"   __       "#,
        r#" /'  '-.    "#,
        r#"| (o)    \  "#,
        r#" \    __ \  "#,
        r#"  /_\ /_\ \."#,
    ],
    // raise_1
    [
        r#"   __       "#,
        r#" /'  '-.    "#,
        r#"| (o)   \_  "#,
        r#" \    __/'  "#,
        r#"  /_\ /_\   "#,
    ],
    // raise_2
    [
        r#"   __       "#,
        r#" /'  '-.    "#,
        r#"| (o)    \__"#,
        r#" \    __/'  "#,
        r#"  /_\ /_\   "#,
    ],
    // raise_3
    [
        r#"   __       "#,
        r#" /'  '-.    "#,
        r#"| (o)   \___"#,
        r#" \    __/'  "#,
        r#"  /_\ /_\   "#,
    ],
    // spray_1
    [
        r#"   __       "#,
        r#" /'  '-.    "#,
        r#"| (o)   \___"#,
        r#" \    __/'  "#,
        r#"  /_\ /_\   "#,
    ],
];
static COMPACT_TIP_ROWS: [usize; 11] = [3, 3, 3, 3, 4, 4, 4, 2, 2, 2, 2];

/// Most steps a walk takes; longer walks take wider steps.
const MAX_WALK_STEPS: i64 = 60;
/// Frames between two droplets of the spray.
const SPRAY_INTERVAL: i64 = 3;
/// Most impacts (droplets) in a spray; bigger texts get bigger patches.
const MAX_IMPACTS: usize = 96;
/// Patch radius in columns (rows count double).
const IMPACT_RADIUS: f64 = 3.5;
/// Columns the ripple spreads per frame after an impact.
const RIPPLE_SPEED: f64 = 1.5;
/// Layers: dry text, sprite and puddle, wet text, flying water.
const LAYER_DRY: i32 = 1;
const LAYER_SPRITE: i32 = 2;
const LAYER_WET: i32 = 3;
const LAYER_WATER: i32 = 4;

/// TTE 0.15's find_normalized_distance_from_center (the original's reveal
/// bands): the distance from the rectangle's center, rows scaled by two,
/// over the corner distance. (utils::geometry has the older formula.)
fn normalized_distance_from_center(bottom: i64, top: i64, left: i64, right: i64, c: Coord) -> f64 {
    let center_column = (left + right) as f64 / 2.0;
    let center_row = (bottom + top) as f64 / 2.0;
    let max = ((right - left) as f64 / 2.0).hypot((top - bottom) as f64 / 2.0 * 2.0);
    if max == 0.0 {
        return 0.0;
    }
    let distance = (c.column as f64 - center_column).hypot((c.row as f64 - center_row) * 2.0);
    (distance / max).min(1.0)
}

/// Columns per step so that `distance` takes at most MAX_WALK_STEPS steps.
fn stride_for(distance: i64) -> i64 {
    ((distance.max(0) + MAX_WALK_STEPS - 1) / MAX_WALK_STEPS).max(1)
}

fn lerp_color(a: Color, b: Color, t: f64) -> Color {
    let t = t.clamp(0.0, 1.0);
    let (ar, ag, ab) = a.rgb_ints();
    let (br, bg, bb) = b.rgb_ints();
    let mix = |x: u8, y: u8| -> u8 {
        (x as f64 + (y as f64 - x as f64) * t)
            .round()
            .clamp(0.0, 255.0) as u8
    };
    Color::from_rgb(mix(ar, br), mix(ag, bg), mix(ab, bb))
}

fn scale_color(c: Color, factor: f64) -> Color {
    let f = factor.clamp(0.0, 1.5);
    let (r, g, b) = c.rgb_ints();
    let s = |v: u8| -> u8 { (v as f64 * f).round().clamp(0.0, 255.0) as u8 };
    Color::from_rgb(s(r), s(g), s(b))
}

/// No effect callbacks are used.
struct NoHooks;
impl Hooks for NoHooks {}

fn other(message: String) -> EngineError {
    EngineError::Other(message)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Full,
    Compact,
    Fallback,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    WalkIn,
    Drink,
    RaiseTrunk,
    Splash,
    Reveal,
    Celebrate,
    WalkOut,
    Hold,
    Complete,
}

/// Where the elephant stops: (origin column, baseline row). It faces right,
/// so it stands under the text if the canvas is tall enough, left of it if
/// wide enough, else at the left edge (and the wet text covers it).
fn parking_spot(
    canvas: &crate::engine::canvas::Canvas,
    width: i64,
    height: i64,
    puddle_width: i64,
) -> (i64, i64) {
    let max_x = canvas.left.max(canvas.right - width + 1);
    let below = canvas.text_bottom - 2 - height;
    if below >= canvas.bottom {
        let x = canvas.text_center_column - (width + puddle_width) / 2;
        return (x.clamp(canvas.left, max_x), below.max(canvas.bottom));
    }
    if canvas.text_left - canvas.left > width {
        return (
            (canvas.text_left - width - 1).clamp(canvas.left, max_x),
            canvas.bottom,
        );
    }
    (canvas.left, canvas.bottom)
}

/// The rigid, pose-driven sprite.
struct Elephant {
    width: usize,
    /// Per pose: per cell (sprite row 0 = bottom, row-major) the symbol and
    /// colors.
    looks: Vec<Vec<(Sym, ColorPair, bool)>>,
    tip_offsets: Vec<Coord>,
    cells: Vec<u32>,
    x: i64,
    y: i64,
    target_column: i64,
    exit_column: i64,
    /// Columns per step for the walk in and the walk out.
    stride_in: i64,
    stride_out: i64,
    walk_frame: i64,
    step_frame: i64,
    pose: usize,
    /// The (pose, x, y) last drawn.
    drawn: Option<(usize, i64, i64)>,
}

impl Elephant {
    #[allow(clippy::too_many_arguments)]
    fn new(
        e: &mut Engine,
        config: &ElephantSplashConfig,
        poses: &[&[&str]],
        tip_rows: &[usize],
        width: usize,
        height: usize,
        target: (i64, i64),
    ) -> Self {
        let canvas = e.canvas.clone();
        let shadow = Animation::adjust_color_brightness(&config.elephant_color, 0.65);
        let mut looks = Vec::with_capacity(poses.len());
        for pose in poses {
            let mut cells = Vec::with_capacity(width * height);
            for row in 0..height {
                let line = pose[height - row - 1].as_bytes();
                for column in 0..width {
                    let symbol = line.get(column).copied().unwrap_or(b' ');
                    let near = &line[column.saturating_sub(1)..(column + 2).min(line.len())];
                    let color = if matches!(symbol, b'e' | b'o' | b'>') || near.contains(&b'(') {
                        config.elephant_highlight_color
                    } else if row <= 1 {
                        shadow
                    } else {
                        config.elephant_color
                    };
                    let sym = e.sym(std::str::from_utf8(&[symbol]).unwrap_or(" "));
                    cells.push((sym, ColorPair::new(Some(color), None), symbol != b' '));
                }
            }
            looks.push(cells);
        }
        let tip_offsets = poses
            .iter()
            .zip(tip_rows)
            .map(|(pose, &row_index)| {
                let column = pose[row_index]
                    .bytes()
                    .rposition(|b| b != b' ')
                    .unwrap_or(0);
                Coord::new(column as i64, (height - row_index - 1) as i64)
            })
            .collect();
        let (target_column, y) = target;
        // the head already peeks in on the first frame
        let peek = (width as i64 / 3).min(12);
        let x = (canvas.left - width as i64 + peek).min(target_column);
        let exit_column = canvas.right + 1;
        let space = e.sym(" ");
        let mut cells = Vec::with_capacity(width * height);
        for row in 0..height {
            for column in 0..width {
                let slot =
                    e.add_character_sym(space, Coord::new(x + column as i64, y + row as i64));
                e.set_layer(slot, LAYER_SPRITE);
                cells.push(slot);
            }
        }
        let mut elephant = Elephant {
            width,
            looks,
            tip_offsets,
            cells,
            x,
            y,
            target_column,
            exit_column,
            stride_in: stride_for(target_column - x),
            stride_out: stride_for(exit_column - target_column),
            walk_frame: 0,
            step_frame: 0,
            pose: WALK_1,
            drawn: None,
        };
        elephant.apply_pose(e, WALK_1);
        elephant
    }

    fn tip(&self, pose: usize, x: i64, y: i64) -> Coord {
        let o = self.tip_offsets[pose];
        Coord::new(x + o.column, y + o.row)
    }

    fn trunk(&self) -> Coord {
        self.tip(self.pose, self.x, self.y)
    }

    fn apply_pose(&mut self, e: &mut Engine, pose: usize) {
        self.pose = pose;
        if self.drawn == Some((pose, self.x, self.y)) {
            return;
        }
        let moved = self
            .drawn
            .is_none_or(|(_, x, y)| x != self.x || y != self.y);
        let restyled = self.drawn.is_none_or(|(p, _, _)| p != pose);
        self.drawn = Some((pose, self.x, self.y));
        let canvas = &e.canvas;
        let (left, right, bottom, top) = (canvas.left, canvas.right, canvas.bottom, canvas.top);
        for (i, &slot) in self.cells.iter().enumerate() {
            let (row, column) = (i / self.width, i % self.width);
            let (sym, colors, solid) = self.looks[pose][i];
            if restyled {
                e.set_appearance(slot, Some(sym), Some(colors));
            }
            let coord = Coord::new(self.x + column as i64, self.y + row as i64);
            if moved {
                e.set_coordinate(slot, coord);
            }
            let inside = left <= coord.column
                && coord.column <= right
                && bottom <= coord.row
                && coord.row <= top;
            e.set_visible(slot, solid && inside);
        }
    }

    /// step_walk: the central walk cycle and `stride`-column steps.
    fn step_walk(
        &mut self,
        e: &mut Engine,
        direction: i64,
        stride: i64,
        limit: Option<i64>,
        config: &ElephantSplashConfig,
    ) -> bool {
        let pose = WALK_1 + ((self.walk_frame / config.walk_pose_frames) % WALK_POSES) as usize;
        self.step_frame += 1;
        if self.step_frame >= config.horizontal_step_frames {
            let mut next = self.x + direction * stride;
            if let Some(limit) = limit {
                next = if direction > 0 {
                    next.min(limit)
                } else {
                    next.max(limit)
                };
            }
            self.x = next;
            self.step_frame = 0;
        }
        self.apply_pose(e, pose);
        self.walk_frame += 1;
        limit.is_some_and(|limit| self.x == limit)
    }

    fn start_walk_out(&mut self, e: &mut Engine) {
        self.walk_frame = 0;
        self.step_frame = 0;
        self.apply_pose(e, WALK_1);
    }

    fn hide(&mut self, e: &mut Engine) {
        for &slot in &self.cells {
            e.set_visible(slot, false);
        }
        self.drawn = None;
    }
}

/// The puddle on the canvas floor.
struct Puddle {
    width: usize,
    height: usize,
    start_column: i64,
    baseline: i64,
    chars: Vec<u32>,
    /// Symbols for the ripple: ".", "~", "_", "o", " ".
    syms: [Sym; 5],
}

impl Puddle {
    fn new(
        e: &mut Engine,
        colors: &[Color],
        width: usize,
        height: usize,
        near_column: i64,
        baseline: i64,
    ) -> Self {
        let canvas = e.canvas.clone();
        let start_column = canvas
            .left
            .max(near_column.min(canvas.right - width as i64 + 1));
        let rows: &[&str] = if height == 2 {
            &["  .~~~~~~~~~.  ", ".~~~~~~~~~~~~~."]
        } else {
            &["~~~"]
        };
        let mut chars = Vec::new();
        for (row_offset, symbols) in rows.iter().rev().enumerate() {
            for (column_offset, symbol) in symbols.chars().enumerate() {
                let sym = e.symbols.intern_char(symbol);
                let coord = Coord::new(
                    start_column + column_offset as i64,
                    baseline + row_offset as i64,
                );
                let slot = e.add_character_sym(sym, coord);
                e.set_layer(slot, LAYER_SPRITE);
                let color = colors[(row_offset + column_offset) % colors.len()];
                e.set_appearance(slot, Some(sym), Some(ColorPair::new(Some(color), None)));
                let inside = coord.column <= canvas.right && coord.row <= canvas.top;
                e.set_visible(slot, inside);
                chars.push(slot);
            }
        }
        let syms = [e.sym("."), e.sym("~"), e.sym("_"), e.sym("o"), e.sym(" ")];
        Puddle {
            width,
            height,
            start_column,
            baseline,
            chars,
            syms,
        }
    }

    fn ripple(&self, e: &mut Engine, colors: &[Color], frame: i64) {
        let [dot, tilde, under, bubble, space] = self.syms;
        let w = self.width as i64;
        let step = frame / 6;
        let bubble_column = 2 + (step * 2) % (w - 4).max(1);
        for (index, &slot) in self.chars.iter().enumerate() {
            let (row_offset, column) = ((index / self.width) as i64, (index % self.width) as i64);
            let sym = if self.height == 1 {
                if (column + step) % 2 != 0 {
                    tilde
                } else {
                    under
                }
            } else if row_offset == 0 {
                if column == 0 || column == w - 1 {
                    dot
                } else if (column + step) % 2 == 0 {
                    tilde
                } else {
                    under
                }
            } else if column == bubble_column {
                bubble
            } else if 2 <= column && column < w - 2 && (column + step) % 3 == 0 {
                tilde
            } else {
                space
            };
            let color = colors[((row_offset + column + step) as usize) % colors.len()];
            e.set_appearance(slot, Some(sym), Some(ColorPair::new(Some(color), None)));
        }
    }

    fn shrink_to(&self, e: &mut Engine, visible_count: i64) {
        let h = self.height as i64;
        let columns = (self.width as i64).min((visible_count.max(0) + h - 1) / h);
        let center = (self.width as f64 - 1.0) / 2.0;
        let mut order: Vec<usize> = (0..self.width).collect();
        order.sort_by(|&a, &b| {
            (a as f64 - center)
                .abs()
                .partial_cmp(&(b as f64 - center).abs())
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        let mut keep = vec![false; self.width];
        for &column in order.iter().take(columns.max(0) as usize) {
            keep[column] = true;
        }
        let canvas = &e.canvas;
        let (right, top) = (canvas.right, canvas.top);
        for (index, &slot) in self.chars.iter().enumerate() {
            let coord = Coord::new(
                self.start_column + (index % self.width) as i64,
                self.baseline + (index / self.width) as i64,
            );
            let inside = coord.column <= right && coord.row <= top;
            e.set_visible(slot, keep[index % self.width] && inside);
        }
    }
}

/// Maximum concurrent dripping drops during the post-splash flourish.
const MAX_FLOURISH_DROPS: usize = 14;
/// Maximum width of the post-splash puddle (keeps big canvases fast & focused).
const MAX_FLOURISH_PUDDLE_WIDTH: i64 = 140;
/// Maximum simultaneous wave-packet ripples in the post-splash puddle.
const MAX_FLOURISH_RIPPLES: usize = 28;

#[derive(Clone, Copy)]
struct FlourishSyms {
    b1: Sym, // ▁
    b2: Sym, // ▂
    b3: Sym, // ▃
    b4: Sym, // ▄
    b5: Sym, // ▅
    top_half: Sym, // ▀
    top_thin: Sym, // ▔
    q_bl: Sym, // ▖
    q_br: Sym, // ▗
    q_tl: Sym, // ▘
    q_tr: Sym, // ▝
    shade: Sym, // ░
    drop_slow: Sym, // ╻
    drop_fast: Sym, // │
    drop_trail: Sym, // ╵
    tilde: Sym, // ~
}

impl FlourishSyms {
    fn intern(e: &mut Engine) -> Self {
        FlourishSyms {
            b1: e.sym("▁"),
            b2: e.sym("▂"),
            b3: e.sym("▃"),
            b4: e.sym("▄"),
            b5: e.sym("▅"),
            top_half: e.sym("▀"),
            top_thin: e.sym("▔"),
            q_bl: e.sym("▖"),
            q_br: e.sym("▗"),
            q_tl: e.sym("▘"),
            q_tr: e.sym("▝"),
            shade: e.sym("░"),
            drop_slow: e.sym("╻"),
            drop_fast: e.sym("│"),
            drop_trail: e.sym("╵"),
            tilde: e.sym("~"),
        }
    }
}

struct DripSource {
    slot: u32,
    col: i64,
    row: i64,
    final_color: Color,
}

#[derive(Clone, Copy)]
enum DropState {
    Idle,
    Beading {
        source_idx: usize,
        age: i64,
        duration: i64,
    },
    Falling {
        col: i64,
        start_row: i64,
        age: i64,
    },
    Splashing {
        col: i64,
        age: i64,
    },
}

struct FallingDrop {
    head: u32,
    trail: u32,
    splash_l: u32,
    splash_r: u32,
    state: DropState,
}

struct Ripple {
    col: f64,
    born: i64,
    amplitude: f64,
    speed: f64,
}

/// After-splash signature flourish: beads of water gather on the undersides of
/// the freshly drenched letters, fall under gravity into a shimmering puddle
/// below the logo, send expanding concentric ripples across its surface (with
/// a wobbling reflection of the letters), and then gently evaporate to leave
/// the crisp finished logo.
struct DripFlourish {
    puddle_left: i64,
    puddle_width: usize,
    puddle_rows: usize,
    surface_row: i64,
    text_bottom: i64,
    puddle_cells: Vec<u32>,
    reflect_colors: Vec<Option<Color>>,
    col_wetness: Vec<f64>,
    sources: Vec<DripSource>,
    drops: Vec<FallingDrop>,
    ripples: Vec<Ripple>,
    next_spawn_frame: i64,
    glint_allowed: bool,
    cleaned: bool,
    syms: FlourishSyms,
}

impl DripFlourish {
    fn build(
        e: &mut Engine,
        input: &[u32],
        final_colors: &[Color],
    ) -> Option<Self> {
        if input.is_empty() {
            return None;
        }
        let canvas = e.canvas.clone();
        let space_below = canvas.text_bottom - canvas.bottom;
        if space_below < 1 {
            return None;
        }

        let (puddle_rows, surface_row) = if space_below >= 9 {
            let rows = 3usize;
            let gap = ((space_below - rows as i64) * 2 / 3).clamp(3, 7);
            (rows, canvas.text_bottom - gap)
        } else if space_below >= 4 {
            let rows = 2usize;
            let gap = ((space_below - rows as i64) * 3 / 4).clamp(2, 5);
            (rows, canvas.text_bottom - gap)
        } else {
            (1usize, canvas.bottom)
        };
        let surface_row = surface_row.max(canvas.bottom + puddle_rows as i64 - 1);

        let text_w = (canvas.text_right - canvas.text_left + 1).max(1);
        let margin = ((canvas.width - text_w) / 12).clamp(2, 10);
        let mut left = (canvas.text_left - margin).max(canvas.left);
        let mut right = (canvas.text_right + margin).min(canvas.right);
        if right - left + 1 > MAX_FLOURISH_PUDDLE_WIDTH {
            let half = MAX_FLOURISH_PUDDLE_WIDTH / 2;
            left = (canvas.text_center_column - half).max(canvas.left);
            right = (left + MAX_FLOURISH_PUDDLE_WIDTH - 1).min(canvas.right);
            left = (right - MAX_FLOURISH_PUDDLE_WIDTH + 1).max(canvas.left);
        }
        let puddle_width = (right - left + 1).max(0) as usize;
        if puddle_width == 0 {
            return None;
        }

        let space_sym = e.sym(" ");
        let mut solid_coords: std::collections::HashSet<(i64, i64)> =
            std::collections::HashSet::with_capacity(input.len());
        for &slot in input {
            if e.input_sym(slot) != space_sym {
                let c = e.input_coord(slot);
                solid_coords.insert((c.column, c.row));
            }
        }

        // Find bottom-edge letter cells with a clear vertical drop path to the puddle.
        let mut sources = Vec::new();
        let mut reflect_colors: Vec<Option<Color>> = vec![None; puddle_width];
        let mut reflect_lowest: Vec<i64> = vec![i64::MAX; puddle_width];
        for (&slot, &final_color) in input.iter().zip(final_colors.iter()) {
            if e.input_sym(slot) == space_sym {
                continue;
            }
            let c = e.input_coord(slot);
            if c.column < left || c.column > right || c.row <= surface_row {
                continue;
            }
            let dx = (c.column - left) as usize;
            if c.row < reflect_lowest[dx] {
                reflect_lowest[dx] = c.row;
                reflect_colors[dx] = Some(final_color);
            }
            if solid_coords.contains(&(c.column, c.row - 1)) {
                continue;
            }
            // Ensure no other letter sits directly below this underside cell.
            let clear = (surface_row..c.row).all(|r| !solid_coords.contains(&(c.column, r)));
            if clear {
                sources.push(DripSource {
                    slot,
                    col: c.column,
                    row: c.row,
                    final_color,
                });
            }
        }
        if sources.is_empty() {
            return None;
        }
        // Sort deterministically left-to-right, then bottom-to-top.
        sources.sort_by_key(|s| (s.col, s.row));

        let syms = FlourishSyms::intern(e);
        let mut puddle_cells = Vec::with_capacity(puddle_rows * puddle_width);
        for dy in 0..puddle_rows {
            let row = surface_row - dy as i64;
            for dx in 0..puddle_width {
                let coord = Coord::new(left + dx as i64, row);
                let slot = e.add_character_sym(syms.b1, coord);
                e.set_layer(slot, LAYER_SPRITE);
                e.set_visible(slot, false);
                puddle_cells.push(slot);
            }
        }

        let origin = Coord::new(left, surface_row);
        let drop_count = MAX_FLOURISH_DROPS.min(sources.len().max(1));
        let mut drops = Vec::with_capacity(drop_count);
        for _ in 0..drop_count {
            let make = |e: &mut Engine, sym: Sym| {
                let slot = e.add_character_sym(sym, origin);
                e.set_layer(slot, LAYER_WATER);
                e.set_visible(slot, false);
                slot
            };
            let head = make(e, syms.top_thin);
            let trail = make(e, syms.drop_trail);
            let splash_l = make(e, syms.q_bl);
            let splash_r = make(e, syms.q_br);
            drops.push(FallingDrop {
                head,
                trail,
                splash_l,
                splash_r,
                state: DropState::Idle,
            });
        }

        let glint_allowed = e.existing_color_handling() == ExistingColorHandling::Ignore;

        Some(DripFlourish {
            puddle_left: left,
            puddle_width,
            puddle_rows,
            surface_row,
            text_bottom: canvas.text_bottom,
            puddle_cells,
            reflect_colors,
            col_wetness: vec![0.0; puddle_width],
            sources,
            drops,
            ripples: Vec::with_capacity(MAX_FLOURISH_RIPPLES),
            next_spawn_frame: 0,
            glint_allowed,
            cleaned: false,
            syms,
        })
    }

    fn cleanup(&mut self, e: &mut Engine) {
        if self.cleaned {
            return;
        }
        self.cleaned = true;
        for &slot in &self.puddle_cells {
            e.set_visible(slot, false);
        }
        for drop in &mut self.drops {
            if let DropState::Beading { source_idx, .. } = drop.state {
                if self.glint_allowed {
                    let src = &self.sources[source_idx];
                    e.set_appearance(
                        src.slot,
                        None,
                        Some(ColorPair::new(Some(src.final_color), None)),
                    );
                }
            }
            e.set_visible(drop.head, false);
            e.set_visible(drop.trail, false);
            e.set_visible(drop.splash_l, false);
            e.set_visible(drop.splash_r, false);
            drop.state = DropState::Idle;
        }
        self.ripples.clear();
    }

    fn step(&mut self, e: &mut Engine, frame: i64, total_frames: i64, water: &[Color]) {
        if total_frames < 20 {
            self.cleanup(e);
            return;
        }
        let clean_tail = (total_frames / 18).clamp(8, 24);
        let active_end = total_frames - clean_tail;
        if frame >= active_end {
            self.cleanup(e);
            return;
        }
        self.cleaned = false;

        let evap_start = (active_end as f64 * 0.76) as i64;
        let drip_stop = (active_end as f64 * 0.68) as i64;

        let w_deep = water[0];
        let w_mid = water[water.len() / 2];
        let w_bright = *water.last().unwrap_or(&w_deep);
        let syms = self.syms;
        let canvas = e.canvas.clone();

        // Spawn a new beading drop on an underside letter cell.
        if frame <= drip_stop && frame >= self.next_spawn_frame {
            if let Some(idle_idx) = self
                .drops
                .iter()
                .position(|d| matches!(d.state, DropState::Idle))
            {
                let active_cols: Vec<i64> = self
                    .drops
                    .iter()
                    .filter_map(|d| match d.state {
                        DropState::Beading { source_idx, .. } => {
                            Some(self.sources[source_idx].col)
                        }
                        DropState::Falling { col, .. } | DropState::Splashing { col, .. } => {
                            Some(col)
                        }
                        DropState::Idle => None,
                    })
                    .collect();

                let mut chosen = e.rng.choice_index(self.sources.len());
                for _ in 0..8 {
                    let cand = e.rng.choice_index(self.sources.len());
                    let col = self.sources[cand].col;
                    if active_cols.iter().all(|&ac| (ac - col).abs() >= 6) {
                        chosen = cand;
                        break;
                    }
                }
                let duration = e.rng.randint(12, 18);
                self.drops[idle_idx].state = DropState::Beading {
                    source_idx: chosen,
                    age: 0,
                    duration,
                };
                // Brisk initial burst so multiple drops visibly drip across OMARCHY.
                let gap = if frame < 60 {
                    e.rng.randint(5, 9)
                } else {
                    e.rng.randint(7, 13)
                };
                self.next_spawn_frame = frame + gap;
            }
        }

        // Advance every active drop: Beading -> Falling -> Splashing -> Idle.
        let mut new_impacts: Vec<i64> = Vec::new();
        for drop in &mut self.drops {
            match drop.state {
                DropState::Idle => {}
                DropState::Beading {
                    source_idx,
                    age,
                    duration,
                } => {
                    let src = &self.sources[source_idx];
                    let bead_row = src.row - 1;
                    if age >= duration {
                        if self.glint_allowed {
                            e.set_appearance(
                                src.slot,
                                None,
                                Some(ColorPair::new(Some(src.final_color), None)),
                            );
                        }
                        drop.state = DropState::Falling {
                            col: src.col,
                            start_row: bead_row,
                            age: 0,
                        };
                    } else {
                        let frac = age as f64 / duration.max(1) as f64;
                        let sym = if frac < 0.55 {
                            syms.top_thin
                        } else {
                            syms.top_half
                        };
                        let col_rgb = lerp_color(w_mid, w_bright, frac);
                        e.set_coordinate(drop.head, Coord::new(src.col, bead_row));
                        e.set_appearance(
                            drop.head,
                            Some(sym),
                            Some(ColorPair::new(Some(col_rgb), None)),
                        );
                        e.set_visible(drop.head, bead_row > self.surface_row);
                        e.set_visible(drop.trail, false);
                        if self.glint_allowed {
                            let glint =
                                lerp_color(src.final_color, w_bright, 0.28 * (1.0 - (frac - 0.5).abs() * 2.0).max(0.0));
                            e.set_appearance(
                                src.slot,
                                None,
                                Some(ColorPair::new(Some(glint), None)),
                            );
                        }
                        drop.state = DropState::Beading {
                            source_idx,
                            age: age + 1,
                            duration,
                        };
                    }
                }
                DropState::Falling {
                    col,
                    start_row,
                    age,
                } => {
                    let t = age as f64;
                    let g = 0.022;
                    let y_f = start_row as f64 - 0.5 * g * t * t;
                    let cur_row = y_f.floor() as i64;
                    if cur_row <= self.surface_row {
                        e.set_visible(drop.head, false);
                        e.set_visible(drop.trail, false);
                        new_impacts.push(col);
                        drop.state = DropState::Splashing { col, age: 0 };
                    } else {
                        let vel = g * t;
                        let head_sym = if vel < 0.16 {
                            syms.drop_slow
                        } else {
                            syms.drop_fast
                        };
                        e.set_coordinate(drop.head, Coord::new(col, cur_row));
                        e.set_appearance(
                            drop.head,
                            Some(head_sym),
                            Some(ColorPair::new(Some(w_bright), None)),
                        );
                        e.set_visible(drop.head, true);

                        let trail_row = cur_row + 1;
                        if vel >= 0.16 && trail_row <= start_row {
                            e.set_coordinate(drop.trail, Coord::new(col, trail_row));
                            e.set_appearance(
                                drop.trail,
                                Some(syms.drop_trail),
                                Some(ColorPair::new(Some(w_mid), None)),
                            );
                            e.set_visible(drop.trail, true);
                        } else {
                            e.set_visible(drop.trail, false);
                        }
                        drop.state = DropState::Falling {
                            col,
                            start_row,
                            age: age + 1,
                        };
                    }
                }
                DropState::Splashing { col, age } => {
                    let splash_row = self.surface_row + 1;
                    let can_show = splash_row < self.text_bottom && splash_row <= canvas.top;
                    if age >= 15 || !can_show {
                        e.set_visible(drop.splash_l, false);
                        e.set_visible(drop.splash_r, false);
                        drop.state = DropState::Idle;
                    } else {
                        let (offset, sym_l, sym_r, color) = if age < 4 {
                            (1, syms.q_bl, syms.q_br, w_bright)
                        } else if age < 9 {
                            (2, syms.q_tl, syms.q_tr, w_mid)
                        } else {
                            (1, syms.b1, syms.b1, scale_color(w_deep, 0.75))
                        };
                        let cl = col - offset;
                        let cr = col + offset;
                        if cl >= canvas.left && cl <= canvas.right {
                            e.set_coordinate(drop.splash_l, Coord::new(cl, splash_row));
                            e.set_appearance(
                                drop.splash_l,
                                Some(sym_l),
                                Some(ColorPair::new(Some(color), None)),
                            );
                            e.set_visible(drop.splash_l, true);
                        } else {
                            e.set_visible(drop.splash_l, false);
                        }
                        if cr >= canvas.left && cr <= canvas.right {
                            e.set_coordinate(drop.splash_r, Coord::new(cr, splash_row));
                            e.set_appearance(
                                drop.splash_r,
                                Some(sym_r),
                                Some(ColorPair::new(Some(color), None)),
                            );
                            e.set_visible(drop.splash_r, true);
                        } else {
                            e.set_visible(drop.splash_r, false);
                        }
                        drop.state = DropState::Splashing { col, age: age + 1 };
                    }
                }
            }
        }

        // Register impacts into the puddle's ripple field and local wetness.
        for col in new_impacts {
            if self.ripples.len() >= MAX_FLOURISH_RIPPLES {
                self.ripples.remove(0);
            }
            let amp = 0.92 + (e.rng.randint(0, 32) as f64) / 100.0;
            self.ripples.push(Ripple {
                col: col as f64,
                born: frame,
                amplitude: amp,
                speed: 0.36,
            });
            let center_dx = col - self.puddle_left;
            for dx in 0..self.puddle_width {
                let d = (dx as i64 - center_dx).abs() as f64;
                if d <= 16.0 {
                    let boost = 0.45 * (1.0 - d / 16.0);
                    self.col_wetness[dx] = (self.col_wetness[dx] + boost).min(1.0);
                }
            }
        }
        self.ripples.retain(|r| frame - r.born < 130);

        // Global puddle growth and smooth evaporation envelope.
        let grow = (frame as f64 / 55.0).clamp(0.18, 1.0);
        let evap = if frame >= evap_start {
            let u = ((frame - evap_start) as f64 / (active_end - evap_start).max(1) as f64)
                .clamp(0.0, 1.0);
            1.0 - (3.0 * u * u - 2.0 * u * u * u)
        } else {
            1.0
        };
        let global_fill = grow * evap;

        // Render the puddle surface and reflection/depth rows.
        let w = self.puddle_width;
        let w_f = w as f64;
        for dx in 0..w {
            let x = (self.puddle_left + dx as i64) as f64;
            let nx = (dx as f64 + 0.5) / w_f * 2.0 - 1.0;
            let edge = (1.0 - nx * nx).max(0.0).sqrt();
            let presence = (global_fill * 0.65 + self.col_wetness[dx] * 0.35 * evap) * edge;

            // Superpose expanding damped wave packets from all active ripples.
            let mut h = 0.05 * (x * 0.33 + frame as f64 * 0.055).sin();
            for r in &self.ripples {
                let age = (frame - r.born) as f64;
                let dist = (x - r.col).abs();
                let front = r.speed * age;
                let delta = dist - front;
                let sigma = 2.1 + 0.035 * age;
                if delta.abs() > sigma * 3.2 {
                    continue;
                }
                let env = (-(delta * delta) / (2.0 * sigma * sigma)).exp();
                let damp = (-age / 48.0).exp() * (-dist / 30.0).exp();
                let osc = (delta * 1.15).cos();
                h += r.amplitude * env * damp * osc;
            }
            h *= evap;

            // Row 0: dynamic water surface with fractional block wave height.
            let slot0 = self.puddle_cells[dx];
            let lvl = 0.30 * presence + 0.65 * h * (0.35 + 0.65 * presence);
            if presence < 0.06 || lvl <= 0.04 {
                e.set_visible(slot0, false);
            } else {
                let sym = if lvl < 0.22 {
                    syms.b1
                } else if lvl < 0.42 {
                    syms.b2
                } else if lvl < 0.65 {
                    syms.b3
                } else if lvl < 0.88 {
                    syms.b4
                } else {
                    syms.b5
                };
                let base_fg = if h > 0.08 {
                    lerp_color(w_deep, w_bright, (h * 0.95).clamp(0.0, 1.0))
                } else if h < -0.10 {
                    scale_color(w_deep, 0.68)
                } else {
                    lerp_color(w_deep, w_mid, (0.35 * presence).clamp(0.0, 1.0))
                };
                let fg = scale_color(base_fg, 0.45 + 0.55 * evap.min(1.0) * (0.5 + 0.5 * edge));
                let bg = if lvl >= 0.30 && presence >= 0.25 {
                    Some(scale_color(w_deep, 0.14 * presence))
                } else {
                    None
                };
                e.set_appearance(slot0, Some(sym), Some(ColorPair::new(Some(fg), bg)));
                e.set_visible(slot0, true);
            }

            // Row 1: soft water depth + wobbling reflection of the letters above.
            if self.puddle_rows >= 2 {
                let slot1 = self.puddle_cells[w + dx];
                let edge1 = (1.0 - (nx * 1.10).powi(2)).max(0.0).sqrt();
                let pres1 = presence * edge1;
                if pres1 < 0.14 {
                    e.set_visible(slot1, false);
                } else {
                    let shift = (h * 1.8).round() as isize;
                    let ref_dx = (dx as isize + shift).clamp(0, (w - 1) as isize) as usize;
                    let bg = Some(scale_color(
                        w_deep,
                        0.17 * pres1 * (1.0 + 0.35 * h.clamp(-0.5, 0.8)),
                    ));
                    let (sym, fg) = if let Some(ref_col) = self.reflect_colors[ref_dx] {
                        let blended = lerp_color(ref_col, w_mid, 0.32);
                        let sym = if h > 0.18 {
                            syms.top_half
                        } else if h < -0.15 {
                            syms.shade
                        } else {
                            syms.top_thin
                        };
                        (sym, scale_color(blended, (0.58 + 0.30 * h.max(0.0)) * pres1))
                    } else {
                        let sym = if h > 0.18 { syms.tilde } else { syms.top_thin };
                        (sym, scale_color(w_deep, (0.38 + 0.25 * h.max(0.0)) * pres1))
                    };
                    e.set_appearance(slot1, Some(sym), Some(ColorPair::new(Some(fg), bg)));
                    e.set_visible(slot1, true);
                }
            }

            // Row 2: tapered bottom shimmer edge into black.
            if self.puddle_rows >= 3 {
                let slot2 = self.puddle_cells[2 * w + dx];
                let edge2 = (1.0 - (nx * 1.26).powi(2)).max(0.0).sqrt();
                let pres2 = presence * edge2;
                if pres2 < 0.22 {
                    e.set_visible(slot2, false);
                } else {
                    let sym = if h > 0.24 {
                        syms.top_half
                    } else {
                        syms.top_thin
                    };
                    let fg = scale_color(w_deep, (0.34 + 0.28 * h.max(0.0)) * pres2);
                    e.set_appearance(slot2, Some(sym), Some(ColorPair::new(Some(fg), None)));
                    e.set_visible(slot2, true);
                }
            }
        }
    }
}

/// One droplet of the spray and the patch of text it wets.
struct Impact {
    center: Coord,
    droplet: u32,
    path: u32,
    scene: u32,
    /// Indexes into `input` with the ripple delay after landing, by delay.
    patch: Vec<(usize, i64)>,
    next: usize,
    emitted: bool,
    landed_at: Option<i64>,
}

pub struct ElephantSplash {
    config: ElephantSplashConfig,
    water: Vec<Color>,
    mode: Mode,
    phase: Phase,
    phase_frame: i64,
    input: Vec<u32>,
    /// Per input character: its reveal has started.
    wet: Vec<bool>,
    bands: Vec<Vec<u32>>,
    next_band: usize,
    reveal: Name,
    elephant: Option<Elephant>,
    puddle: Option<Puddle>,
    flourish: Option<DripFlourish>,
    final_colors: Vec<Color>,
    intake: Vec<u32>,
    intake_syms: [Sym; 3],
    impacts: Vec<Impact>,
    emitted: usize,
    returning_to_walk: bool,
    /// ElephantState.SETTLING during the walk-in.
    settling: bool,
    dot: Sym,
    star: Sym,
}

impl ElephantSplash {
    pub fn new(config: ElephantSplashConfig) -> Self {
        ElephantSplash {
            config,
            water: Vec::new(),
            mode: Mode::Fallback,
            phase: Phase::Complete,
            phase_frame: 0,
            input: Vec::new(),
            wet: Vec::new(),
            bands: Vec::new(),
            next_band: 0,
            reveal: Name::NONE,
            elephant: None,
            puddle: None,
            flourish: None,
            final_colors: Vec::new(),
            intake: Vec::new(),
            intake_syms: [Sym(NONE); 3],
            impacts: Vec::new(),
            emitted: 0,
            returning_to_walk: false,
            settling: false,
            dot: Sym(NONE),
            star: Sym(NONE),
        }
    }
}

impl Hooks for ElephantSplash {}

impl ElephantSplash {
    /// The dry text, the reveal scenes and the radial bands.
    fn build_reveal(&mut self, e: &mut Engine) -> Result<(), EngineError> {
        let config = self.config.clone();
        let canvas = e.canvas.clone();
        self.bands = vec![Vec::new(); REVEAL_BANDS];
        self.wet = vec![false; self.input.len()];
        self.final_colors = Vec::with_capacity(self.input.len());
        if self.input.is_empty() {
            return Ok(());
        }
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
        let (start, finish) = (self.water[0], *self.water.last().expect("water"));
        let frames = config.final_gradient_frames.clamp(1, MAX_FRAME_DURATION);
        for &slot in &self.input.clone() {
            let input = e.input_coord(slot);
            let distance = normalized_distance_from_center(
                canvas.text_bottom,
                canvas.text_top,
                canvas.text_left,
                canvas.text_right,
                input,
            );
            let band = ((distance * REVEAL_BANDS as f64) as usize).min(REVEAL_BANDS - 1);
            self.bands[band].push(slot);

            let to = mapping
                .get(&input)
                .copied()
                .unwrap_or(*gradient.spectrum.last().expect("gradient"));
            self.final_colors.push(to);
            // dry: a dim outline of the final look
            let sym = e.input_sym(slot);
            let dry = Animation::adjust_color_brightness(&to, 0.16);
            e.set_layer(slot, LAYER_DRY);
            e.set_appearance(slot, Some(sym), Some(ColorPair::new(Some(dry), None)));
            e.set_visible(slot, true);

            let scene = e.scene_new(slot, self.reveal, false, None, None);
            e.add_frame(
                scene,
                self.star,
                2,
                Some(ColorPair::new(Some(finish), None)),
                0,
            )
            .map_err(other)?;
            e.add_frame(
                scene,
                self.dot,
                2,
                Some(ColorPair::new(Some(start), None)),
                0,
            )
            .map_err(other)?;
            let cool = |to: Color| Gradient::with_steps(&[start, to], 12, false).map(|g| g.spectrum);
            if dynamic {
                let fg = e.input_fg(slot).map(cool).transpose().map_err(other)?;
                let bg = e.input_bg(slot).map(cool).transpose().map_err(other)?;
                if fg.is_some() || bg.is_some() {
                    e.apply_gradient(scene, &[sym], frames, fg.as_deref(), bg.as_deref())
                        .map_err(other)?;
                } else {
                    e.add_frame(scene, sym, frames, Some(ColorPair::default()), 0)
                        .map_err(other)?;
                }
            } else {
                let spectrum = cool(to).map_err(other)?;
                e.apply_gradient(scene, &[sym], frames, Some(&spectrum), None)
                    .map_err(other)?;
            }
        }
        Ok(())
    }

    /// Cover the text with patches, left to right: each patch is centered a
    /// little right of the leftmost still-dry character and takes every dry
    /// character within the radius. The radius grows until there are at
    /// most MAX_IMPACTS patches.
    fn plan_patches(&self, e: &mut Engine) -> Vec<(Coord, Vec<(usize, i64)>)> {
        if self.input.is_empty() {
            return Vec::new();
        }
        let coords: Vec<Coord> = self.input.iter().map(|&s| e.input_coord(s)).collect();
        let min_c = coords.iter().map(|c| c.column).min().unwrap_or(0);
        let max_c = coords.iter().map(|c| c.column).max().unwrap_or(0);
        let min_r = coords.iter().map(|c| c.row).min().unwrap_or(0);
        let max_r = coords.iter().map(|c| c.row).max().unwrap_or(0);
        let (w, h) = (max_c - min_c + 1, max_r - min_r + 1);
        let mut grid = vec![usize::MAX; (w * h) as usize];
        for (i, c) in coords.iter().enumerate() {
            grid[((c.row - min_r) * w + (c.column - min_c)) as usize] = i;
        }
        let mut order: Vec<usize> = (0..coords.len()).collect();
        order.sort_by_key(|&i| (coords[i].column, coords[i].row));
        let mut radius = IMPACT_RADIUS;
        loop {
            let mut taken = vec![false; coords.len()];
            let mut patches = Vec::new();
            for &seed in &order {
                if taken[seed] {
                    continue;
                }
                let c = coords[seed];
                let center = Coord::new((c.column + (radius * 0.6) as i64).min(max_c), c.row);
                let reach = radius.ceil() as i64;
                let mut patch = Vec::new();
                for row in (center.row - reach / 2 - 1).max(min_r)
                    ..=(center.row + reach / 2 + 1).min(max_r)
                {
                    for column in
                        (center.column - reach).max(min_c)..=(center.column + reach).min(max_c)
                    {
                        let i = grid[((row - min_r) * w + (column - min_c)) as usize];
                        if i == usize::MAX || taken[i] {
                            continue;
                        }
                        let d = ((column - center.column) as f64)
                            .hypot((row - center.row) as f64 * 2.0);
                        if d <= radius {
                            taken[i] = true;
                            patch.push((i, (d / RIPPLE_SPEED).round() as i64));
                        }
                    }
                }
                if !taken[seed] {
                    taken[seed] = true;
                    patch.push((seed, (radius / RIPPLE_SPEED).round() as i64));
                }
                patches.push((center, patch));
            }
            if patches.len() <= MAX_IMPACTS || radius > (w + 2 * h) as f64 {
                // a frame of jitter keeps the ripples from looking stamped
                for (_, patch) in &mut patches {
                    for entry in patch.iter_mut() {
                        entry.1 += e.rng.randint(0, 1);
                    }
                    patch.sort_by_key(|&(i, d)| (d, i));
                }
                return patches;
            }
            radius *= 1.35;
        }
    }

    fn build_droplets(&mut self, e: &mut Engine) -> Result<(), EngineError> {
        let symbols = [e.sym("."), e.sym("o"), e.sym("*"), e.sym("'")];
        let droplet = e.name("droplet");
        let origin = Coord::new(0, 0);
        for (center, patch) in self.plan_patches(e) {
            let sym = symbols[e.rng.choice_index(symbols.len())];
            let slot = e.add_character_sym(sym, origin);
            e.set_layer(slot, LAYER_WATER);
            let scene = e.scene_new(slot, droplet, true, None, None);
            for &color in &self.water {
                e.add_frame(scene, sym, 3, Some(ColorPair::new(Some(color), None)), 0)
                    .map_err(other)?;
            }
            let path = e
                .path_new(
                    slot,
                    self.droplet_speed(),
                    Some(Easing::OutSine),
                    None,
                    0,
                    false,
                    Name::NONE,
                )
                .map_err(other)?;
            self.impacts.push(Impact {
                center,
                droplet: slot,
                path,
                scene,
                patch,
                next: 0,
                emitted: false,
                landed_at: None,
            });
        }
        Ok(())
    }

    fn droplet_speed(&self) -> f64 {
        DROPLET_SPEED * (self.config.movement_speed / DEFAULT_MOVEMENT_SPEED)
    }

    /// Fire the next droplet from the trunk along a high arc.
    fn emit_droplet(&mut self, e: &mut Engine) {
        let Some(elephant) = &self.elephant else {
            return;
        };
        let origin = elephant.trunk();
        let canvas = e.canvas.clone();
        let impact = &mut self.impacts[self.emitted];
        let target = impact.center;
        let distance =
            ((target.column - origin.column) as f64).hypot((target.row - origin.row) as f64 * 2.0);
        let lift = 3 + (distance / 5.0) as i64 + (self.emitted % 3) as i64;
        let control_row = canvas.top.min(origin.row.max(target.row) + lift);
        let control = Coord::new((origin.column + target.column).div_euclid(2), control_row);
        let slot = impact.droplet;
        e.deactivate_path(slot, None);
        e.set_coordinate(slot, origin);
        impact.emitted = true;
        self.emitted += 1;
        if target == origin {
            // nothing to fly: with no active path it lands right away
            return;
        }
        e.path_reset(impact.path);
        e.path_new_waypoint(impact.path, target, Some(&[control]), Name::NONE)
            .expect("anonymous waypoint");
        e.activate_path(&mut NoHooks, slot, impact.path);
        e.activate_scene(&mut NoHooks, slot, impact.scene);
        e.set_visible(slot, true);
        e.active_insert(slot);
    }

    /// Start one character's reveal: it gets wet and moves in front.
    fn wet_char(&mut self, e: &mut Engine, index: usize) {
        if self.wet[index] {
            return;
        }
        self.wet[index] = true;
        let slot = self.input[index];
        e.set_layer(slot, LAYER_WET);
        e.set_visible(slot, true);
        e.activate_scene_name(&mut NoHooks, slot, self.reveal);
        e.active_insert(slot);
    }

    /// Land finished droplets and spread their ripples.
    fn spread_water(&mut self, e: &mut Engine) {
        let frame = self.phase_frame;
        let mut wets = Vec::new();
        for impact in &mut self.impacts {
            if impact.emitted
                && impact.landed_at.is_none()
                && e.ch.path[impact.droplet as usize] == NONE
            {
                impact.landed_at = Some(frame);
                e.set_visible(impact.droplet, false);
                e.deactivate_scene(impact.droplet, None);
                e.active_remove(impact.droplet);
            }
            if let Some(landed) = impact.landed_at {
                while impact.next < impact.patch.len()
                    && impact.patch[impact.next].1 <= frame - landed
                {
                    wets.push(impact.patch[impact.next].0);
                    impact.next += 1;
                }
            }
        }
        for index in wets {
            self.wet_char(e, index);
        }
    }

    fn animate_intake(&mut self, e: &mut Engine) {
        let (Some(elephant), Some(puddle)) = (&self.elephant, &self.puddle) else {
            return;
        };
        let origin = Coord::new(
            puddle.start_column + puddle.width as i64 / 2,
            puddle.baseline + puddle.height as i64 - 1,
        );
        let destination = elephant.trunk();
        let pf = self.phase_frame;
        for (index, &slot) in self.intake.iter().enumerate() {
            let index = index as i64;
            let progress = ((pf / 3 + index * 3) % 10 + 1) as f64 / 10.0;
            let coord = Coord::new(
                round_half_even(
                    origin.column as f64 + (destination.column - origin.column) as f64 * progress,
                ),
                round_half_even(
                    origin.row as f64 + (destination.row - origin.row) as f64 * progress,
                ),
            );
            e.set_coordinate(slot, coord);
            let sym = self.intake_syms[((pf / 4 + index) % 3) as usize];
            let color = self.water[((pf / 6 + index) as usize) % self.water.len()];
            e.set_appearance(slot, Some(sym), Some(ColorPair::new(Some(color), None)));
            e.set_visible(slot, true);
        }
    }

    // ------------------------------------------------------------ phases

    fn step_walk_in(&mut self, e: &mut Engine) {
        let config = self.config.clone();
        if let Some(puddle) = &self.puddle {
            puddle.ripple(e, &self.water, self.phase_frame);
        }
        let Some(elephant) = self.elephant.as_mut() else {
            self.phase = Phase::Splash;
            return;
        };
        if !self.settling {
            let (target, stride) = (elephant.target_column, elephant.stride_in);
            let reached = elephant.step_walk(e, 1, stride, Some(target), &config);
            if reached {
                self.settling = true;
                self.phase_frame = 0;
            } else {
                self.phase_frame += 1;
            }
            return;
        }
        let cycle = config.walk_pose_frames.saturating_mul(WALK_POSES);
        if elephant.walk_frame % cycle != 0 {
            elephant.step_walk(e, 0, 0, None, &config);
            return;
        }
        elephant.apply_pose(e, WALK_1);
        self.phase_frame += 1;
        if self.phase_frame >= SETTLE_FRAMES {
            self.phase = Phase::Drink;
            self.phase_frame = 0;
        }
    }

    fn step_drink(&mut self, e: &mut Engine) {
        let (Some(elephant), Some(puddle)) = (self.elephant.as_mut(), self.puddle.as_ref()) else {
            self.phase = Phase::RaiseTrunk;
            return;
        };
        puddle.ripple(e, &self.water, self.phase_frame);
        let pose = (self.phase_frame / (DRINK_FRAMES / 3) + 1).min(3);
        elephant.apply_pose(e, DRINK_1 + pose as usize - 1);
        self.animate_intake(e);
        self.phase_frame += 1;
        let puddle = self.puddle.as_ref().expect("puddle");
        let total = puddle.chars.len() as i64;
        let remaining = total - self.phase_frame * total / DRINK_FRAMES;
        puddle.shrink_to(e, remaining.max(0));
        if self.phase_frame >= DRINK_FRAMES {
            for &slot in &self.intake {
                e.set_visible(slot, false);
            }
            self.phase = Phase::RaiseTrunk;
            self.phase_frame = 0;
        }
    }

    fn step_raise_trunk(&mut self, e: &mut Engine) {
        let Some(elephant) = self.elephant.as_mut() else {
            self.phase = Phase::Splash;
            return;
        };
        if self.returning_to_walk {
            let pose = (3 - self.phase_frame / 10).max(1);
            elephant.apply_pose(e, RAISE_1 + pose as usize - 1);
            self.phase_frame += 1;
            if self.phase_frame >= RAISE_FRAMES {
                self.returning_to_walk = false;
                elephant.start_walk_out(e);
                self.phase = Phase::WalkOut;
                self.phase_frame = 0;
            }
            return;
        }
        let pose = (self.phase_frame / 10 + 1).min(3);
        elephant.apply_pose(e, RAISE_1 + pose as usize - 1);
        self.phase_frame += 1;
        if self.phase_frame >= RAISE_FRAMES {
            self.phase = Phase::Splash;
            self.phase_frame = 0;
        }
    }

    fn step_splash(&mut self, e: &mut Engine) {
        if self.elephant.is_none() {
            let early = self.phase_frame < 3;
            let sym = if early { self.dot } else { self.star };
            let color = if early {
                self.water[0]
            } else {
                *self.water.last().expect("water")
            };
            for &slot in &self.input {
                e.set_visible(slot, true);
                e.set_appearance(slot, Some(sym), Some(ColorPair::new(Some(color), None)));
            }
            self.phase_frame += 1;
            if self.phase_frame >= 6 {
                self.phase = Phase::Reveal;
                self.phase_frame = 0;
            }
            return;
        }
        if let Some(elephant) = self.elephant.as_mut() {
            elephant.apply_pose(e, SPRAY_1);
        }
        if self.emitted < self.impacts.len() && self.phase_frame % SPRAY_INTERVAL == 0 {
            self.emit_droplet(e);
        }
        e.update(&mut NoHooks);
        self.spread_water(e);
        self.phase_frame += 1;
        let done = self.impacts.iter().all(|i| i.next == i.patch.len());
        if self.emitted >= self.impacts.len() && done {
            // anything the water missed is swept up by the radial bands
            let wet = &self.wet;
            let input = &self.input;
            let dry: std::collections::HashSet<u32> = (0..input.len())
                .filter(|&i| !wet[i])
                .map(|i| input[i])
                .collect();
            for band in &mut self.bands {
                band.retain(|slot| dry.contains(slot));
            }
            self.bands.retain(|band| !band.is_empty());
            self.next_band = 0;
            self.phase = Phase::Reveal;
            self.phase_frame = 0;
        }
    }

    fn step_reveal(&mut self, e: &mut Engine) {
        if self.phase_frame % 2 == 0 && self.next_band < self.bands.len() {
            for &slot in &self.bands[self.next_band] {
                e.set_layer(slot, LAYER_WET);
                e.set_visible(slot, true);
                e.activate_scene_name(&mut NoHooks, slot, self.reveal);
                e.active_insert(slot);
            }
            self.next_band += 1;
        }
        if let Some(elephant) = self.elephant.as_mut() {
            elephant.apply_pose(e, SPRAY_1);
        }
        e.update(&mut NoHooks);
        self.phase_frame += 1;
        let busy = self.input.iter().any(|&slot| e.active_contains(slot));
        if self.next_band == self.bands.len() && !busy {
            if self.elephant.is_some() {
                self.phase = Phase::Celebrate;
                self.phase_frame = 0;
            } else {
                self.phase = Phase::Hold;
                self.phase_frame = 0;
            }
        }
    }

    fn step_celebrate(&mut self, e: &mut Engine) {
        if let Some(elephant) = self.elephant.as_mut() {
            // a happy wave of the trunk, ending raised
            let wave = self.phase_frame >= 20
                && self.phase_frame < CELEBRATE_FRAMES - 20
                && (self.phase_frame / 10) % 2 == 0;
            elephant.apply_pose(e, if wave { RAISE_1 + 1 } else { SPRAY_1 });
        }
        self.phase_frame += 1;
        if self.phase_frame >= CELEBRATE_FRAMES {
            self.returning_to_walk = true;
            self.phase = Phase::RaiseTrunk;
            self.phase_frame = 0;
        }
    }

    fn step_walk_out(&mut self, e: &mut Engine) {
        let config = self.config.clone();
        let Some(elephant) = self.elephant.as_mut() else {
            self.phase = Phase::Hold;
            self.phase_frame = 0;
            return;
        };
        let (exit, stride) = (elephant.exit_column, elephant.stride_out);
        let reached = elephant.step_walk(e, 1, stride, Some(exit), &config);
        self.phase_frame += 1;
        if reached {
            elephant.hide(e);
            self.phase = Phase::Hold;
            self.phase_frame = 0;
        }
    }

    /// False when the hold is over (StopIteration).
    fn step_hold(&mut self, e: &mut Engine) -> bool {
        let total = self.config.final_hold_frames;
        if total <= 0 || self.phase_frame >= total {
            if let Some(flourish) = self.flourish.as_mut() {
                flourish.cleanup(e);
            }
            self.phase = Phase::Complete;
            return false;
        }
        if let Some(flourish) = self.flourish.as_mut() {
            flourish.step(e, self.phase_frame, total, &self.water);
        }
        self.phase_frame += 1;
        true
    }
}

impl Effect for ElephantSplash {
    fn build(&mut self, e: &mut Engine) -> Result<(), EngineError> {
        let config = self.config.clone();
        let canvas = e.canvas.clone();
        self.water = if config.water_colors.is_empty() {
            vec![Color::from_rgb(0x38, 0xBD, 0xF8)]
        } else {
            config.water_colors.clone()
        };
        self.dot = e.sym(".");
        self.star = e.sym("*");
        self.intake_syms = [self.dot, e.sym("o"), self.star];
        self.reveal = e.name("reveal");
        self.mode = if canvas.width >= FULL_WIDTH as i64 && canvas.height >= FULL_HEIGHT as i64 {
            Mode::Full
        } else if canvas.width >= 12 && canvas.height >= 6 {
            Mode::Compact
        } else {
            Mode::Fallback
        };
        self.phase = if self.mode == Mode::Fallback {
            Phase::Splash
        } else {
            Phase::WalkIn
        };
        self.input = e.get_characters(
            CharacterFilter::default(),
            CharacterSort::TopToBottomLeftToRight,
        );
        self.build_reveal(e)?;
        self.flourish = DripFlourish::build(e, &self.input, &self.final_colors);
        if self.mode == Mode::Fallback {
            return Ok(());
        }
        let (puddle_width, puddle_height) = if self.mode == Mode::Compact {
            (3, 1)
        } else {
            (15, 2)
        };
        let elephant = if self.mode == Mode::Full {
            let spot = parking_spot(
                &canvas,
                FULL_WIDTH as i64,
                FULL_HEIGHT as i64,
                puddle_width as i64,
            );
            let poses: Vec<&[&str]> = FULL_POSES.iter().map(|p| &p[..]).collect();
            Elephant::new(
                e,
                &config,
                &poses,
                &FULL_TIP_ROWS,
                FULL_WIDTH,
                FULL_HEIGHT,
                spot,
            )
        } else {
            let spot = parking_spot(
                &canvas,
                COMPACT_WIDTH as i64,
                COMPACT_HEIGHT as i64,
                puddle_width as i64,
            );
            let poses: Vec<&[&str]> = COMPACT_POSES.iter().map(|p| &p[..]).collect();
            Elephant::new(
                e,
                &config,
                &poses,
                &COMPACT_TIP_ROWS,
                COMPACT_WIDTH,
                COMPACT_HEIGHT,
                spot,
            )
        };
        let tip = elephant.tip(DRINK_1, elephant.target_column, elephant.y);
        let puddle = Puddle::new(
            e,
            &self.water,
            puddle_width,
            puddle_height,
            tip.column + 1,
            elephant.y,
        );
        // the intake stream
        let count = if self.mode == Mode::Full { 3 } else { 1 };
        let origin = Coord::new(
            puddle.start_column + puddle.width as i64 / 2,
            puddle.baseline + puddle.height as i64 - 1,
        );
        for index in 0..count {
            let sym = self.intake_syms[index];
            let slot = e.add_character_sym(sym, origin);
            e.set_layer(slot, LAYER_WATER);
            let color = self.water[index % self.water.len()];
            e.set_appearance(slot, Some(sym), Some(ColorPair::new(Some(color), None)));
            self.intake.push(slot);
        }
        self.elephant = Some(elephant);
        self.puddle = Some(puddle);
        self.build_droplets(e)?;
        Ok(())
    }

    fn next_frame(&mut self, e: &mut Engine) -> bool {
        match self.phase {
            Phase::WalkIn => self.step_walk_in(e),
            Phase::Drink => self.step_drink(e),
            Phase::RaiseTrunk => self.step_raise_trunk(e),
            Phase::Splash => self.step_splash(e),
            Phase::Reveal => self.step_reveal(e),
            Phase::Celebrate => self.step_celebrate(e),
            Phase::WalkOut => self.step_walk_out(e),
            Phase::Hold => return self.step_hold(e),
            Phase::Complete => return false,
        }
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
        config: ElephantSplashConfig,
    }

    fn config(args: &[&str]) -> ElephantSplashConfig {
        let mut argv = vec!["elephantsplash"];
        argv.extend_from_slice(args);
        Cli::parse_from(argv).config
    }

    fn engine(
        input: &str,
        width: i64,
        height: i64,
        handling: ExistingColorHandling,
        seed: u64,
    ) -> Engine {
        let terminal = TerminalConfig {
            canvas_width: width,
            canvas_height: height,
            ignore_terminal_dimensions: true,
            existing_color_handling: handling,
            ..TerminalConfig::default()
        };
        Engine::new(
            input,
            terminal,
            Rng::seeded(seed),
            Clock::virtual_with_frame_rate(60),
        )
        .unwrap()
    }

    fn run(
        input: &str,
        width: i64,
        height: i64,
        args: &[&str],
        handling: ExistingColorHandling,
    ) -> (u64, Engine) {
        let mut e = engine(input, width, height, handling, 5);
        let mut effect = ElephantSplash::new(config(args));
        effect.build(&mut e).unwrap();
        let mut frames = 0u64;
        while effect.next_frame(&mut e) {
            frames += 1;
            assert!(frames < 200_000, "elephantsplash did not finish");
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
            assert!(!e.is_visible(slot), "auxiliary character left visible");
        }
    }

    #[test]
    fn runs_to_completion_on_edge_inputs() {
        let ignore = ExistingColorHandling::Ignore;
        let long = "x".repeat(500);
        let cases: Vec<(&str, i64, i64)> = vec![
            ("OMARCHY\nhello world\n", 80, 24),
            ("OMARCHY\nhello world\n", 20, 8),
            ("OMARCHY\nhello world\n", 10, 3),
            ("", 20, 5),
            ("   ", 50, 20),
            ("a", 1, 1),
            ("a", 41, 16),
            (&long, 80, 10),
            (&long, 200, 30),
            ("日本語のテキスト\nwide ✓ chars", 60, 20),
            ("\x1b[31mred\x1b[0m \x1b[44mblue bg\x1b[0m", 50, 18),
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
                if Engine::new(
                    input,
                    terminal,
                    Rng::seeded(1),
                    Clock::virtual_with_frame_rate(60),
                )
                .is_err()
                {
                    continue;
                }
            }
            let (_, e) = run(input, w, h, &[], ignore);
            assert_final(&e, ignore);
            let (_, e) = run(input, w, h, &["--final-hold-frames", "0"], ignore);
            assert_final(&e, ignore);
        }
    }

    #[test]
    fn dynamic_restores_input_colors() {
        for (w, h) in [(80, 24), (20, 8), (10, 3)] {
            let dynamic = ExistingColorHandling::Dynamic;
            let (_, e) = run(
                "\x1b[31mred\x1b[0m plain \x1b[1;42mgreen\x1b[0m",
                w,
                h,
                &[],
                dynamic,
            );
            assert_final(&e, dynamic);
            let always = ExistingColorHandling::Always;
            let (_, e) = run("\x1b[31mred\x1b[0m plain", w, h, &[], always);
            assert_final(&e, always);
        }
    }

    #[test]
    fn deterministic_for_a_seed() {
        let trace = || {
            let mut e = engine(
                "OMARCHY\nhello world",
                60,
                20,
                ExistingColorHandling::Ignore,
                3,
            );
            let mut effect = ElephantSplash::new(config(&[]));
            effect.build(&mut e).unwrap();
            let mut states = Vec::new();
            while effect.next_frame(&mut e) {
                states.push((
                    e.ch.coord.clone(),
                    e.ch.visual.iter().map(|v| v.0).collect::<Vec<_>>(),
                ));
            }
            states
        };
        assert_eq!(trace(), trace());
    }

    #[test]
    fn timing_options_change_the_length() {
        let ignore = ExistingColorHandling::Ignore;
        let input = "OMARCHY\nhello world";
        for (w, h) in [(80, 24), (20, 8)] {
            let base = run(input, w, h, &[], ignore).0;
            for args in [
                &["--walk-pose-frames", "3"][..],
                &["--horizontal-step-frames", "2"][..],
                &["--final-gradient-frames", "9"][..],
                &["--final-hold-frames", "10"][..],
                &["--movement-speed", "0.1"][..],
            ] {
                let frames = run(input, w, h, args, ignore).0;
                assert_ne!(
                    frames, base,
                    "{args:?} did not change the run length at {w}x{h}"
                );
            }
        }
        // the fallback has no sprite: the reveal and the hold set its length
        let base = run(input, 10, 3, &[], ignore).0;
        for args in [
            &["--final-gradient-frames", "9"][..],
            &["--final-hold-frames", "10"][..],
        ] {
            assert_ne!(run(input, 10, 3, args, ignore).0, base);
        }
    }

    #[test]
    fn logo_run_length_and_opening() {
        let logo = std::fs::read_to_string("/usr/share/omarchy/logo.txt")
            .unwrap_or_else(|_| "OMARCHY OMARCHY OMARCHY\n".repeat(8));
        let ignore = ExistingColorHandling::Ignore;
        for (w, h) in [(96, 24), (200, 55), (300, 90)] {
            let mut e = engine(&logo, w, h, ignore, 7);
            let mut effect = ElephantSplash::new(config(&[]));
            effect.build(&mut e).unwrap();
            assert!(effect.next_frame(&mut e));
            // the dry text and the elephant are on screen from the first frame
            assert!(
                e.input_chars.iter().all(|&s| e.is_visible(s)),
                "dry text hidden at {w}x{h}"
            );
            assert!(
                e.added_chars.iter().any(|&s| e.is_visible(s)),
                "empty stage at {w}x{h}"
            );
            let mut frames = 1u64;
            while effect.next_frame(&mut e) {
                frames += 1;
            }
            assert!(
                (960..=2400).contains(&frames),
                "{frames} frames at {w}x{h}"
            );
            assert_final(&e, ignore);
        }
    }
}
