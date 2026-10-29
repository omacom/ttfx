//! Engine::path_position: targeted tests drive the engine's own stepping and
//! compare against the geometry the step is defined by (exact bits, with
//! non-integer positions so the rounded coord cannot pass for the point);
//! a sweep over every effect checks each point rounds to its character's
//! coordinate and that the kernels record bit-identical points.

use clap::{CommandFactory, Parser};
use ttfx::cli::Cli;
use ttfx::engine::canvas::Anchor;
use ttfx::engine::ctx::Clock;
use ttfx::engine::terminal::TerminalConfig;
use ttfx::fx::batch::kernels;
use ttfx::fx::{Action, Caller, Engine, Event, Hooks, Name};
use ttfx::utils::easing::Easing;
use ttfx::utils::geometry::{self, Coord, FloatPoint};
use ttfx::utils::pycompat::round_half_even;
use ttfx::utils::rng::Rng;

struct NoHooks;
impl Hooks for NoHooks {}

fn engine(text: &str, seed: u64) -> Engine {
    let config = TerminalConfig {
        canvas_width: 24,
        canvas_height: 8,
        ignore_terminal_dimensions: true,
        anchor_text: Anchor::C,
        ..Default::default()
    };
    let clock = Clock::virtual_with_frame_rate(config.frame_rate);
    Engine::new(text, config, Rng::seeded(seed), clock).unwrap()
}

fn bits(p: FloatPoint) -> (u64, u64) {
    (p.column.to_bits(), p.row.to_bits())
}

fn rounds_to_coord(e: &Engine, slot: u32, p: FloatPoint) {
    let c = e.coord(slot);
    assert_eq!(
        (round_half_even(p.column), round_half_even(p.row)),
        (c.column, c.row),
        "{p:?}"
    );
}

/// Slot 0 on a new path to `end` (through `control`, if any), activated
/// from `start`; returns the path.
fn setup(
    e: &mut Engine,
    start: Coord,
    end: Coord,
    control: Option<&[Coord]>,
    speed: f64,
    ease: Option<Easing>,
    hold: i64,
) -> u32 {
    e.set_coordinate(0, start);
    let path = e.path_new(0, speed, ease, None, hold, false, Name::NONE).unwrap();
    e.path_new_waypoint(path, end, control, Name::NONE).unwrap();
    e.activate_path(&mut NoHooks, 0, path);
    path
}

/// `path_step`'s t for a lone unclamped-or-clamped segment: the eased or
/// linear factor times the total, over the segment's length.
fn t_of(factor: f64, dist: f64, eased: bool) -> f64 {
    let t = factor * dist / dist;
    if eased {
        t
    } else {
        t.min(1.0)
    }
}

#[test]
fn none_without_path_or_before_first_step() {
    let mut e = engine("abc", 1);
    assert_eq!(e.path_position(0), None);
    let (start, end) = (Coord::new(0, 0), Coord::new(7, 3));
    setup(&mut e, start, end, None, 1.0, None, 0);
    assert_eq!(e.path_position(0), None);
    e.motion_move(&mut NoHooks, 0);
    assert!(e.path_position(0).is_some());
}

#[test]
fn linear_steps_are_the_exact_line_points() {
    let mut e = engine("abc", 1);
    let (start, end) = (Coord::new(1, 0), Coord::new(8, 3));
    let dist = geometry::find_length_of_line(start, end, true);
    let speed = 1.3;
    let max = round_half_even(dist / speed);
    setup(&mut e, start, end, None, speed, None, 1);
    let mut off_cell = 0;
    for k in 1..=max {
        e.motion_move(&mut NoHooks, 0);
        let want = geometry::point_on_line(start, end, t_of(k as f64 / max as f64, dist, false));
        let got = e.path_position(0).unwrap();
        assert_eq!(bits(got), bits(want), "step {k}");
        rounds_to_coord(&e, 0, got);
        assert_eq!(e.coord(0), geometry::find_coord_on_line(start, end, t_of(k as f64 / max as f64, dist, false)));
        off_cell += (got.column.fract() != 0.0 || got.row.fract() != 0.0) as usize;
    }
    assert!(off_cell >= 3, "{off_cell} steps off whole cells");
}

#[test]
fn bezier_steps_are_the_exact_curve_points() {
    let mut e = engine("abc", 1);
    let (start, end, control) = (Coord::new(0, 6), Coord::new(11, 5), [Coord::new(4, 0)]);
    let dist = geometry::find_length_of_bezier_curve(start, &control, end);
    let speed = 1.7;
    let max = round_half_even(dist / speed);
    setup(&mut e, start, end, Some(&control), speed, None, 1);
    let mut off_cell = 0;
    for k in 1..=max {
        e.motion_move(&mut NoHooks, 0);
        let t = t_of(k as f64 / max as f64, dist, false);
        let want = geometry::point_on_bezier_curve(start, &control, end, t);
        let got = e.path_position(0).unwrap();
        assert_eq!(bits(got), bits(want), "step {k}");
        rounds_to_coord(&e, 0, got);
        off_cell += (got.column.fract() != 0.0 || got.row.fract() != 0.0) as usize;
    }
    assert!(off_cell >= 3, "{off_cell} steps off whole cells");
}

#[test]
fn holding_at_the_end_is_the_end_waypoint() {
    for control in [None, Some([Coord::new(3, 7)])] {
        let mut e = engine("abc", 1);
        let (start, end) = (Coord::new(2, 1), Coord::new(9, 4));
        let path = setup(&mut e, start, end, control.as_ref().map(|c| &c[..]), 1.9, None, 4);
        let max = e.path_history(path).0 / 1.9;
        for _ in 0..round_half_even(max) + 3 {
            e.motion_move(&mut NoHooks, 0);
        }
        // still on the path, holding
        let got = e.path_position(0).expect("holding");
        assert_eq!(bits(got), bits(FloatPoint { column: 9.0, row: 4.0 }));
        assert_eq!(e.coord(0), end);
    }
}

#[test]
fn set_coordinate_clears_until_next_step() {
    let mut e = engine("abc", 1);
    setup(&mut e, Coord::new(0, 0), Coord::new(9, 4), None, 1.0, None, 0);
    e.motion_move(&mut NoHooks, 0);
    e.motion_move(&mut NoHooks, 0);
    assert!(e.path_position(0).is_some());
    e.set_coordinate(0, Coord::new(5, 5));
    assert_eq!(e.path_position(0), None);
    e.motion_move(&mut NoHooks, 0);
    let got = e.path_position(0).expect("next step");
    rounds_to_coord(&e, 0, got);
}

#[test]
fn deactivate_reset_and_activate_keep_the_point() {
    let mut e = engine("abc", 1);
    let path = setup(&mut e, Coord::new(0, 0), Coord::new(9, 4), None, 1.3, None, 0);
    e.motion_move(&mut NoHooks, 0);
    let p = e.path_position(0).unwrap();
    assert_ne!((p.column.fract(), p.row.fract()), (0.0, 0.0));
    // the character stays where the step put it
    e.deactivate_path(0, None);
    assert_eq!(e.path_position(0), Some(p));
    e.activate_path(&mut NoHooks, 0, path);
    assert_eq!(e.path_position(0), Some(p));
    e.path_reset(path);
    assert_eq!(e.path_position(0), Some(p));
    e.path_new_waypoint(path, Coord::new(3, 2), None, Name::NONE).unwrap();
    e.activate_path(&mut NoHooks, 0, path);
    e.motion_move(&mut NoHooks, 0);
    let q = e.path_position(0).unwrap();
    assert_ne!(bits(q), bits(p));
    rounds_to_coord(&e, 0, q);
}

/// Activates its path on the character whose callback runs.
struct Switch(u32);
impl Hooks for Switch {
    fn callback(&mut self, e: &mut Engine, slot: u32, _id: u32, _arg: i64) {
        e.activate_path(&mut NoHooks, slot, self.0);
    }
}

#[test]
fn a_path_activated_mid_step_keeps_the_point_placed() {
    let mut e = engine("abc", 1);
    e.set_coordinate(0, Coord::new(0, 0));
    let a = e.path_new(0, 1.3, None, None, 0, false, Name::NONE).unwrap();
    e.path_new_waypoint(a, Coord::new(5, 1), None, Name::NONE).unwrap();
    let wp = e.path_new_waypoint(a, Coord::new(11, 3), None, Name::NONE).unwrap();
    let b = e.path_new(0, 1.3, None, None, 0, false, Name::NONE).unwrap();
    e.path_new_waypoint(b, Coord::new(0, 6), None, Name::NONE).unwrap();
    e.register_event(0, Event::SegmentEntered, Caller::Waypoint(wp.key()), Action::Callback(0, 0))
        .unwrap();
    e.activate_path(&mut NoHooks, 0, a);
    let mut hooks = Switch(b);
    while e.ch.path[0] == a {
        e.motion_move(&mut hooks, 0);
    }
    // the walk on `a` finished the step the callback interrupted
    let p = e.path_position(0).expect("the step's point");
    rounds_to_coord(&e, 0, p);
    assert_ne!((p.column.fract(), p.row.fract()), (0.0, 0.0));
    assert!(p.column > 5.0, "{p:?} is not on a's second segment");
    e.motion_move(&mut NoHooks, 0);
    let q = e.path_position(0).expect("b's first step");
    assert_ne!(bits(q), bits(p));
    rounds_to_coord(&e, 0, q);
}

/// Reads slot 1's position whenever a callback runs.
struct Peek(Vec<Option<FloatPoint>>);
impl Hooks for Peek {
    fn callback(&mut self, e: &mut Engine, _slot: u32, _id: u32, _arg: i64) {
        self.0.push(e.path_position(1));
    }
}

#[test]
fn a_callback_sees_no_step_not_taken_yet() {
    for tier in kernels() {
        let mut e = engine("ab", 1);
        e.use_kernel(tier);
        // slot 1: a long path without events, which the batch steps
        e.set_coordinate(1, Coord::new(0, 7));
        let long = e.path_new(1, 0.7, None, None, 0, false, Name::NONE).unwrap();
        e.path_new_waypoint(long, Coord::new(23, 0), None, Name::NONE).unwrap();
        e.activate_path(&mut NoHooks, 1, long);
        // slot 0, ticked first: entering its second segment runs a callback
        e.set_coordinate(0, Coord::new(0, 0));
        let short = e.path_new(0, 1.0, None, None, 0, false, Name::NONE).unwrap();
        e.path_new_waypoint(short, Coord::new(4, 0), None, Name::NONE).unwrap();
        let wp = e.path_new_waypoint(short, Coord::new(8, 0), None, Name::NONE).unwrap();
        e.register_event(0, Event::SegmentEntered, Caller::Waypoint(wp.key()), Action::Callback(0, 0))
            .unwrap();
        e.activate_path(&mut NoHooks, 0, short);
        e.active_insert(0);
        e.active_insert(1);
        let mut peek = Peek(Vec::new());
        let mut fired = false;
        for frame in 0..12 {
            let before = e.path_position(1);
            e.update(&mut peek);
            if let Some(seen) = peek.0.pop() {
                assert_eq!(seen.map(bits), before.map(bits), "kernel {tier} frame {frame}");
                assert_ne!(e.path_position(1).map(bits), before.map(bits), "slot 1 moved");
                fired = true;
            }
        }
        assert!(fired, "kernel {tier}: no callback ran");
    }
}

#[test]
fn waypoint_added_mid_flight_keeps_the_point() {
    let mut e = engine("abc", 1);
    let (start, end) = (Coord::new(0, 0), Coord::new(14, 2));
    let dist = geometry::find_length_of_line(start, end, true);
    let max = round_half_even(dist / 1.0);
    let path = setup(&mut e, start, end, None, 1.0, Some(Easing::OutBack), 0);
    // step to an overshot point: past the end, unclamped
    let mut over = None;
    for k in 1..max {
        e.motion_move(&mut NoHooks, 0);
        let p = e.path_position(0).unwrap();
        if p.column > end.column as f64 {
            over = Some((k, p));
            break;
        }
    }
    let (k, before) = over.expect("OutBack overshoots before the last step");
    let want = geometry::point_on_line(start, end, Easing::OutBack.ease(k as f64 / max as f64) * dist / dist);
    assert_eq!(bits(before), bits(want));
    assert_ne!(before.column.fract(), 0.0);
    rounds_to_coord(&e, 0, before);

    e.path_new_waypoint(path, Coord::new(2, 6), None, Name::NONE).unwrap();
    let after = e.path_position(0).expect("kept");
    assert_eq!(bits(after), bits(before));
    rounds_to_coord(&e, 0, after);
}

// ------------------------------------------------------------------- sweep

const TEXT: &str = "path_position\n  rounds to coord\n(0.5) [ab] {cd}";
const SEEDS: [u64; 3] = [1, 7, 2024];
/// Far past any effect's default length on this canvas.
const MAX_FRAMES: usize = 100_000;

#[derive(Default, PartialEq, Debug)]
struct Trace {
    /// FNV-1a of every (frame, slot, point bits) recorded, and None marks.
    hash: u64,
    positions: usize,
    off_cell: usize,
}

/// Run `name` with its default config, asserting every point rounds to its
/// character's coordinate.
fn sweep(name: &str, seed: u64, tier: u8) -> Trace {
    let cli = Cli::try_parse_from(["ttfx", name]).unwrap();
    let mut effect = ttfx::fx::effects::build(cli.effect.as_ref().unwrap())
        .unwrap_or_else(|| panic!("{name}: fx declined the default config"));
    let mut e = engine(TEXT, seed);
    e.use_kernel(tier);
    effect.build(&mut e).unwrap();
    let mut t = Trace {
        hash: 0xcbf29ce484222325,
        ..Default::default()
    };
    let mut mix = |v: u64| {
        t.hash = (t.hash ^ v).wrapping_mul(0x100000001b3);
    };
    let mut frame = 0usize;
    let (mut positions, mut off_cell) = (0, 0);
    while effect.next_frame(&mut e) {
        e.clock.advance_frame();
        e.render_here();
        for slot in 0..e.char_count() as u32 {
            let Some(p) = e.path_position(slot) else {
                mix(u64::MAX);
                continue;
            };
            let c = e.coord(slot);
            assert_eq!(
                (round_half_even(p.column), round_half_even(p.row)),
                (c.column, c.row),
                "{name} seed {seed} frame {frame} slot {slot}: {p:?}"
            );
            mix(p.column.to_bits());
            mix(p.row.to_bits());
            positions += 1;
            off_cell += (p.column.fract() != 0.0 || p.row.fract() != 0.0) as usize;
        }
        frame += 1;
        assert!(frame < MAX_FRAMES, "{name} seed {seed}: no end");
    }
    t.positions = positions;
    t.off_cell = off_cell;
    t
}

#[test]
fn every_effect_rounds_to_coord() {
    let names: Vec<String> = Cli::command()
        .get_subcommands()
        .map(|c| c.get_name().to_string())
        .collect();
    assert!(!names.is_empty());
    let mut first: Vec<Trace> = Vec::new();
    // the widest first, scalar last
    for (k, kernel) in kernels().into_iter().enumerate() {
        let mut i = 0;
        let (mut positions, mut off_cell) = (0, 0);
        for name in &names {
            for &seed in &SEEDS {
                let t = sweep(name, seed, kernel);
                positions += t.positions;
                off_cell += t.off_cell;
                if k == 0 {
                    first.push(t);
                } else {
                    assert_eq!(
                        t, first[i],
                        "{name} seed {seed}: kernel {kernel} records different points than the widest kernel"
                    );
                }
                i += 1;
            }
        }
        assert!(positions > 0, "kernel {kernel}: no effect yields positions");
        assert!(
            off_cell * 10 > positions,
            "kernel {kernel}: only {off_cell} of {positions} positions are off whole cells"
        );
    }
}
