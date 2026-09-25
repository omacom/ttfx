//! Differential tests: assembly functions against their Rust originals
//! (plans/asm-x86.md §9.3). Only built when the assembly engine is linked.
#![cfg(ttfx_asm)]

use std::sync::{Mutex, MutexGuard};

use ttfx::utils::rng::Rng;

/// The engine keeps its state in globals (one engine per process), so tests
/// that call into it take turns.
fn engine() -> MutexGuard<'static, ()> {
    static LOCK: Mutex<()> = Mutex::new(());
    LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

extern "C" {
    fn ttfx_test_rng_randint(state: *mut [u64; 4], a: i64, b: i64) -> i64;
}

/// A deterministic stream of test values, independent of the engine RNG.
pub struct Cases(u64);

impl Cases {
    pub fn new(seed: u64) -> Self {
        Cases(seed)
    }

    pub fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        let x = self.0;
        (x ^ (x >> 29)).wrapping_mul(0xbf58_476d_1ce4_e5b9) ^ (x >> 32)
    }

    pub fn range(&mut self, low: i64, high: i64) -> i64 {
        low + (self.next_u64() % (high - low + 1) as u64) as i64
    }
}

#[test]
fn randint_matches_values_and_state() {
    let _engine = engine();
    let mut cases = Cases::new(1);
    for seed in 0..200u64 {
        let mut rust = Rng::seeded(seed);
        let mut state = rust.state();
        for _ in 0..500 {
            let a = cases.range(-1000, 1000);
            let b = a + cases.range(0, 5000);
            let expected = rust.randint(a, b);
            // SAFETY: the thunk reads and writes exactly four words.
            let got = unsafe { ttfx_test_rng_randint(&mut state, a, b) };
            assert_eq!(got, expected, "randint({a}, {b})");
            assert_eq!(state, rust.state(), "state after randint({a}, {b})");
        }
    }
}

extern "C" {
    fn ttfx_test_rng_uniform(state: *mut [u64; 4], a: f64, b: f64) -> f64;
    fn ttfx_test_rng_shuffle64(state: *mut [u64; 4], values: *mut u64, len: usize);
}

#[test]
fn uniform_matches_bits_and_state() {
    let _engine = engine();
    let mut cases = Cases::new(2);
    for seed in 0..100u64 {
        let mut rust = Rng::seeded(seed);
        let mut state = rust.state();
        for _ in 0..1000 {
            let a = f64::from_bits(cases.next_u64() >> 2) % 1e6 - 5e5;
            let b = a + (cases.next_u64() % 100_000) as f64 / 7.0;
            let expected = rust.uniform(a, b);
            // SAFETY: four state words in and out.
            let got = unsafe { ttfx_test_rng_uniform(&mut state, a, b) };
            assert_eq!(got.to_bits(), expected.to_bits(), "uniform({a}, {b})");
            assert_eq!(state, rust.state());
        }
    }
}

#[test]
fn shuffle_matches_order_and_state() {
    let _engine = engine();
    let mut cases = Cases::new(3);
    for seed in 0..300u64 {
        let mut rust = Rng::seeded(seed);
        let mut state = rust.state();
        let len = cases.range(0, 300) as usize;
        let mut expected: Vec<u64> = (0..len as u64).collect();
        let mut got = expected.clone();
        rust.shuffle(&mut expected);
        // SAFETY: the array has len elements.
        unsafe { ttfx_test_rng_shuffle64(&mut state, got.as_mut_ptr(), len) };
        assert_eq!(got, expected, "shuffle of {len}");
        assert_eq!(state, rust.state());
    }
}

use ttfx::utils::easing::{Easing, EasingTracker, SequenceEaser};

const EASINGS: [Easing; 31] = [
    Easing::Linear,
    Easing::InSine,
    Easing::OutSine,
    Easing::InOutSine,
    Easing::InQuad,
    Easing::OutQuad,
    Easing::InOutQuad,
    Easing::InCubic,
    Easing::OutCubic,
    Easing::InOutCubic,
    Easing::InQuart,
    Easing::OutQuart,
    Easing::InOutQuart,
    Easing::InQuint,
    Easing::OutQuint,
    Easing::InOutQuint,
    Easing::InExpo,
    Easing::OutExpo,
    Easing::InOutExpo,
    Easing::InCirc,
    Easing::OutCirc,
    Easing::InOutCirc,
    Easing::InBack,
    Easing::OutBack,
    Easing::InOutBack,
    Easing::InElastic,
    Easing::OutElastic,
    Easing::InOutElastic,
    Easing::InBounce,
    Easing::OutBounce,
    Easing::InOutBounce,
];

// These words match the NASM strucs; no Rust-owned allocation crosses the ABI.
#[repr(C)]
#[derive(Default)]
struct AsmTracker {
    easing: u64,
    total_steps: i64,
    clamp: u64,
    current_step: i64,
    progress_ratio: f64,
    step_delta: f64,
    eased_value: f64,
    last_eased_value: f64,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct AsmSequenceStep {
    added: *const u64,
    added_count: usize,
    removed: *const u64,
    removed_count: usize,
    current: *const u64,
    current_count: usize,
}

#[repr(C)]
struct AsmSequence {
    tracker: AsmTracker,
    sequence: *const u64,
    length: usize,
    result: AsmSequenceStep,
}

extern "C" {
    fn ttfx_test_ease(id: u32, t: f64) -> f64;
    fn ttfx_test_bezier_easing(params: *const [f64; 4], t: f64) -> f64;
    fn ttfx_test_easing_tracker_new(out: *mut AsmTracker, id: u32, total_steps: i64, clamp: u32);
    fn ttfx_test_easing_tracker_step(tracker: *mut AsmTracker) -> f64;
    fn ttfx_test_easing_tracker_reset(tracker: *mut AsmTracker);
    fn ttfx_test_easing_tracker_is_complete(tracker: *const AsmTracker) -> u32;
    fn ttfx_test_sequence_easer_new(out: *mut AsmSequence, sequence: *const u64, len: usize, id: u32, steps: i64);
    fn ttfx_test_sequence_easer_step(easer: *mut AsmSequence) -> *const AsmSequenceStep;
    fn ttfx_test_sequence_easer_reset(easer: *mut AsmSequence);
    fn ttfx_test_sequence_easer_is_complete(easer: *const AsmSequence) -> u32;
}

#[test]
fn easings_match_bits() {
    let _engine = engine();
    let mut inputs: Vec<f64> = (0..=100_000).map(|i| i as f64 / 100_000.0).collect();
    // Both sides of endpoints, branch thresholds, and bounce breakpoints.
    for t in [0.0_f64, 0.5, 1.0, 1.0 / 2.75, 2.0 / 2.75, 2.5 / 2.75] {
        inputs.extend([t.next_down(), t, t.next_up()]);
    }
    inputs.extend([
        -0.0,
        f64::NEG_INFINITY,
        f64::INFINITY,
        f64::MAX,
        f64::MIN,
        f64::MIN_POSITIVE,
        -f64::MIN_POSITIVE,
        f64::NAN,
        f64::from_bits(0xfff8_0000_0000_1234),
        f64::from_bits(0x7ff0_0000_0000_1234),
    ]);
    let mut cases = Cases::new(4);
    for _ in 0..20_000 {
        inputs.push((cases.next_u64() >> 11) as f64 * (2.0 / (1u64 << 53) as f64) - 0.5);
    }
    // Exponents, subnormals, huge magnitudes, and NaN payloads beyond the grid.
    for _ in 0..20_000 {
        inputs.push(f64::from_bits(cases.next_u64()));
    }
    for (id, easing) in EASINGS.into_iter().enumerate() {
        assert_eq!(easing.asm_id(), Some(id as i64));
        for &t in &inputs {
            // SAFETY: id is a named easing and the scalar follows SysV.
            let got = unsafe { ttfx_test_ease(id as u32, t) };
            assert_eq!(got.to_bits(), easing.ease(t).to_bits(), "{easing:?}({t:?}, bits={:016x})", t.to_bits());
        }
    }
    assert_eq!(Easing::CubicBezier(0.0, 0.0, 1.0, 1.0).asm_id(), None);
}

#[test]
fn bezier_easings_match_bits() {
    let _engine = engine();
    let mut inputs: Vec<f64> = (0..=20_000).map(|i| i as f64 / 20_000.0).collect();
    for t in [0.0_f64, 1.0] {
        inputs.extend([t.next_down(), t, t.next_up()]);
    }
    inputs.extend([-0.0, f64::NEG_INFINITY, f64::INFINITY, f64::NAN, -3.5, 7.25]);
    let mut cases = Cases::new(9);
    let mut unit = move || (cases.next_u64() >> 11) as f64 * (1.0 / (1u64 << 53) as f64);
    // thunderstorm's flash curves, then CSS-style curves with y overshoot,
    // then degenerate derivatives (x1 = x2 = 0 or 1).
    let mut curves: Vec<[f64; 4]> = (0..40).map(|_| [0.0, 1.6, 1.0, -0.6 + 1.0 * unit()]).collect();
    for _ in 0..40 {
        curves.push([unit(), unit() * 3.0 - 1.0, unit(), unit() * 3.0 - 1.0]);
    }
    curves.extend([[0.0, 0.0, 1.0, 1.0], [0.0, 0.0, 0.0, 0.0], [1.0, 1.0, 1.0, 1.0], [0.25, 0.1, 0.25, 1.0]]);
    for curve in &curves {
        let easing = Easing::CubicBezier(curve[0], curve[1], curve[2], curve[3]);
        for &t in &inputs {
            // SAFETY: the pointer is to four f64 and the scalar follows SysV.
            let got = unsafe { ttfx_test_bezier_easing(curve, t) };
            assert_eq!(got.to_bits(), easing.ease(t).to_bits(), "{easing:?}({t:?})");
        }
    }
}

fn check_tracker(got: &AsmTracker, expected: &EasingTracker, clamp: bool) {
    assert_eq!(got.easing as i64, expected.easing_function.asm_id().unwrap());
    assert_eq!(got.total_steps, expected.total_steps);
    assert_eq!(got.clamp, clamp as u64);
    assert_eq!(got.current_step, expected.current_step);
    assert_eq!(got.progress_ratio.to_bits(), expected.progress_ratio.to_bits());
    assert_eq!(got.step_delta.to_bits(), expected.step_delta.to_bits());
    assert_eq!(got.eased_value.to_bits(), expected.eased_value.to_bits());
    assert_eq!(got.last_eased_value.to_bits(), expected.eased_value.to_bits());
    // SAFETY: initialized, correctly sized tracker storage.
    assert_eq!(unsafe { ttfx_test_easing_tracker_is_complete(got) } != 0, expected.is_complete());
}

const STEP_COUNTS: [i64; 13] = [i64::MIN, -1, 0, 1, 2, 3, 7, 16, 31, 100, 257, 1 << 53, i64::MAX];

#[test]
fn easing_trackers_match_every_step_and_reset() {
    let _engine = engine();
    assert_eq!(std::mem::size_of::<AsmTracker>(), 64);
    for easing in EASINGS {
        for steps in STEP_COUNTS {
            for clamp in [false, true] {
                let mut rust = EasingTracker::new(easing, steps, clamp);
                let mut got = AsmTracker::default();
                // SAFETY: each function receives initialized, correctly sized storage.
                unsafe {
                    ttfx_test_easing_tracker_new(&mut got, easing.asm_id().unwrap() as u32, steps, clamp as u32);
                    check_tracker(&got, &rust, clamp);
                    for _ in 0..2 {
                        for _ in 0..steps.clamp(0, 257) + 3 {
                            assert_eq!(
                                ttfx_test_easing_tracker_step(&mut got).to_bits(),
                                rust.step().to_bits(),
                                "{easing:?}, steps={steps}, clamp={clamp}"
                            );
                            check_tracker(&got, &rust, clamp);
                        }
                        ttfx_test_easing_tracker_reset(&mut got);
                        rust.reset();
                        check_tracker(&got, &rust, clamp);
                    }
                    // Reset in the middle of a run as well.
                    ttfx_test_easing_tracker_step(&mut got);
                    rust.step();
                    ttfx_test_easing_tracker_reset(&mut got);
                    rust.reset();
                    check_tracker(&got, &rust, clamp);
                    assert_eq!(ttfx_test_easing_tracker_step(&mut got).to_bits(), rust.step().to_bits());
                    check_tracker(&got, &rust, clamp);
                }
            }
        }
    }
}

// Empty slices can have any pointer in the assembly API, including null.
unsafe fn sequence_slice<'a>(ptr: *const u64, len: usize) -> &'a [u64] {
    if len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ptr, len)
    }
}

#[test]
fn sequence_easers_match_added_removed_current_and_reset() {
    let _engine = engine();
    assert_eq!(std::mem::size_of::<AsmSequence>(), 128);
    let mut saw_removed = false;
    for easing in EASINGS {
        for steps in STEP_COUNTS {
            for len in [0, 1, 2, 3, 7, 31, 100, 257, 1024] {
                let sequence: Vec<u64> = (0..len).map(|i| (i as u64).wrapping_mul(0xf123_4567_89ab_cdef)).collect();
                let mut rust = SequenceEaser::new(sequence.clone(), easing, steps);
                let mut storage = std::mem::MaybeUninit::<AsmSequence>::uninit();
                // SAFETY: new initializes every field. Both arrays outlive the easers,
                // and every returned slice must point into the assembly input array.
                unsafe {
                    ttfx_test_sequence_easer_new(
                        storage.as_mut_ptr(),
                        sequence.as_ptr(),
                        len,
                        easing.asm_id().unwrap() as u32,
                        steps,
                    );
                    let mut got = storage.assume_init();
                    for _ in 0..2 {
                        check_tracker(&got.tracker, &rust.easing_tracker, true);
                        assert_eq!(got.result.current_count, 0);
                        assert_eq!(got.result.added_count, 0);
                        assert_eq!(got.result.removed_count, 0);
                        for _ in 0..steps.clamp(0, 257) + 3 {
                            let expected = rust.step();
                            let result_ptr = ttfx_test_sequence_easer_step(&mut got);
                            assert_eq!(result_ptr, &got.result as *const _);
                            let result = *result_ptr;
                            for (ptr, count) in [
                                (result.added, result.added_count),
                                (result.removed, result.removed_count),
                                (result.current, result.current_count),
                            ] {
                                assert!(count <= len);
                                assert!((ptr as usize) >= sequence.as_ptr() as usize);
                                assert!((ptr as usize) + count * 8 <= sequence.as_ptr() as usize + len * 8);
                            }
                            assert_eq!(
                                sequence_slice(result.added, result.added_count),
                                expected.added,
                                "added {easing:?}, steps={steps}, len={len}"
                            );
                            assert_eq!(
                                sequence_slice(result.removed, result.removed_count),
                                expected.removed,
                                "removed {easing:?}, steps={steps}, len={len}"
                            );
                            saw_removed |= !expected.removed.is_empty();
                            let current_len = (rust.easing_tracker.eased_value * len as f64) as i64 as usize;
                            assert_eq!(sequence_slice(result.current, result.current_count), &sequence[..current_len]);
                            check_tracker(&got.tracker, &rust.easing_tracker, true);
                            assert_eq!(ttfx_test_sequence_easer_is_complete(&got) != 0, rust.is_complete());
                        }
                        ttfx_test_sequence_easer_reset(&mut got);
                        rust.reset();
                    }
                    // Sweep replaces its sequence before resetting for a second phase.
                    let replacement = [u64::MAX, 0, 0x8000_0000_0000_0000];
                    got.sequence = replacement.as_ptr();
                    got.length = replacement.len();
                    rust.sequence = replacement.to_vec();
                    ttfx_test_sequence_easer_reset(&mut got);
                    rust.reset();
                    let result = *ttfx_test_sequence_easer_step(&mut got);
                    let expected = rust.step();
                    assert_eq!(sequence_slice(result.added, result.added_count), expected.added);
                    assert_eq!(sequence_slice(result.removed, result.removed_count), expected.removed);
                }
            }
        }
    }
    assert!(saw_removed);
}

// ---------------------------------------------------------------- pycompat

extern "C" {
    fn ttfx_test_pycompat_round_half_even(x: f64) -> i64;
    fn ttfx_test_pycompat_f64_to_i64(x: f64) -> i64;
    fn ttfx_test_pycompat_floor_div(a: i64, b: i64) -> i64;
    fn ttfx_test_pycompat_py_mod(a: i64, b: i64) -> i64;
}

impl Cases {
    /// A float with a random bit pattern: every exponent, NaNs and
    /// infinities included.
    pub fn any_f64(&mut self) -> f64 {
        f64::from_bits(self.next_u64())
    }

    /// A float in [low, high) with 53 random bits.
    pub fn uniform(&mut self, low: f64, high: f64) -> f64 {
        low + (high - low) * ((self.next_u64() >> 11) as f64 / (1u64 << 53) as f64)
    }

    pub fn coord(&mut self, extent: i64) -> Coord {
        Coord::new(self.range(-extent, extent), self.range(-extent, extent))
    }
}

#[test]
fn round_half_even_and_casts_match() {
    let _engine = engine();
    let mut values: Vec<f64> = vec![
        0.0,
        -0.0,
        0.5,
        -0.5,
        1.5,
        2.5,
        -1.5,
        -2.5,
        0.49999999999999994,
        2.675,
        f64::NAN,
        -f64::NAN,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::MAX,
        f64::MIN,
        f64::MIN_POSITIVE,
        -f64::MIN_POSITIVE,
        f64::EPSILON,
        9.223372036854775e18,
        9.223372036854775807e18,
        -9.223372036854775808e18,
        -9.3e18,
        1e19,
        -1e19,
        1e300,
        -1e300,
    ];
    // the last exactly representable halves and the integer boundaries
    for exponent in 50..=64 {
        let power = (1u64 << exponent) as f64;
        for value in [power, -power] {
            values.extend([value.next_down(), value, value.next_up(), value - 0.5, value + 0.5]);
        }
    }
    for integer in -10_000..=10_000 {
        let halfway = integer as f64 + 0.5;
        values.extend([halfway.next_down(), halfway, halfway.next_up(), integer as f64]);
    }
    let mut cases = Cases::new(11);
    for _ in 0..1_000_000 {
        values.push(cases.any_f64());
    }
    for _ in 0..200_000 {
        values.push(cases.uniform(-1e6, 1e6));
        values.push(cases.uniform(-1e19, 1e19));
    }
    for &x in &values {
        // SAFETY: pure functions of their argument.
        let (rounded, cast) = unsafe { (ttfx_test_pycompat_round_half_even(x), ttfx_test_pycompat_f64_to_i64(x)) };
        assert_eq!(rounded, pycompat::round_half_even(x), "round_half_even({x:e})");
        assert_eq!(cast, x as i64, "{x:e} as i64");
    }
}

#[test]
fn floor_div_and_py_mod_match() {
    let _engine = engine();
    let mut pairs: Vec<(i64, i64)> = Vec::new();
    for a in -60..=60 {
        for b in -60..=60 {
            if b != 0 {
                pairs.push((a, b));
            }
        }
    }
    for a in [i64::MAX, i64::MIN, i64::MAX - 1, i64::MIN + 1, 0, 1, -1] {
        for b in [1, 2, 3, 7, 255, -2, -3, -7, i64::MAX, i64::MIN, i64::MAX - 1] {
            if !(a == i64::MIN && b == -1) {
                pairs.push((a, b));
            }
        }
    }
    let mut cases = Cases::new(12);
    for _ in 0..200_000 {
        let a = cases.next_u64() as i64 >> (cases.range(0, 63) as u32);
        let mut b = cases.next_u64() as i64 >> (cases.range(0, 63) as u32);
        if b == 0 {
            b = 1;
        }
        if !(a == i64::MIN && b == -1) {
            pairs.push((a, b));
        }
    }
    for &(a, b) in &pairs {
        // SAFETY: pure functions; b is never 0 and MIN / -1 is excluded.
        let (div, rem) = unsafe { (ttfx_test_pycompat_floor_div(a, b), ttfx_test_pycompat_py_mod(a, b)) };
        assert_eq!(div, pycompat::floor_div(a, b), "floor_div({a}, {b})");
        assert_eq!(rem, pycompat::py_mod(a, b), "py_mod({a}, {b})");
    }
}

// ---------------------------------------------------------------- geometry

use ttfx::utils::geometry::{self, Coord};
use ttfx::utils::pycompat;

/// A list the engine allocated: rax = pointer, rdx = count.
#[repr(C)]
struct List {
    ptr: *const u64,
    len: u64,
}

impl List {
    fn coords(&self) -> Vec<Coord> {
        // SAFETY: the engine returns len words at ptr, valid until the arena
        // is reset; empty lists still carry an aligned, non-null pointer.
        unsafe { std::slice::from_raw_parts(self.ptr, self.len as usize) }.iter().map(|&w| unpack(w)).collect()
    }
}

extern "C" {
    fn ttfx_test_arena_reset();
    fn ttfx_test_geometry_coords_on_circle(origin: u64, radius: i64, limit: i64, unique: u32) -> List;
    fn ttfx_test_geometry_coords_in_circle(center: u64, diameter: i64) -> List;
    fn ttfx_test_geometry_circle_iter_init(state: *mut u64, center: u64, diameter: i64);
    fn ttfx_test_geometry_circle_iter_next(state: *mut u64, out: *mut u64) -> u32;
    fn ttfx_test_geometry_coords_in_rect(origin: u64, distance: i64) -> List;
    fn ttfx_test_geometry_coords_on_rect(origin: u64, half_width: i64, half_height: i64) -> List;
    fn ttfx_test_geometry_extrapolate_along_ray(origin: u64, target: u64, offset: f64) -> u64;
    fn ttfx_test_geometry_coord_on_bezier_curve(start: u64, control: *const u64, count: u64, end: u64, t: f64) -> u64;
    fn ttfx_test_geometry_coord_on_line(start: u64, end: u64, t: f64) -> u64;
    fn ttfx_test_geometry_length_of_bezier_curve(start: u64, control: *const u64, count: u64, end: u64) -> f64;
    fn ttfx_test_geometry_length_of_line(a: u64, b: u64, double_row_diff: u32) -> f64;
    fn ttfx_test_geometry_normalized_distance(
        bottom: i64,
        top: i64,
        left: i64,
        right: i64,
        coord: u64,
        out: *mut f64,
    ) -> u32;
}

/// The engine's coordinate word: column in the low half, row in the high
/// half, both i32. Expected values are packed the same way, so the contract
/// tested is "the low 32 bits of Rust's i64", which is what the engine keeps.
fn pack(c: Coord) -> u64 {
    (c.column as i32 as u32 as u64) | ((c.row as i32 as u32 as u64) << 32)
}

fn unpack(w: u64) -> Coord {
    Coord::new(w as i32 as i64, (w >> 32) as i32 as i64)
}

fn packed(coords: &[Coord]) -> Vec<Coord> {
    coords.iter().map(|&c| unpack(pack(c))).collect()
}

fn arena_reset() {
    // SAFETY: the test holds the engine lock; no list from an earlier reset
    // is read afterwards.
    unsafe { ttfx_test_arena_reset() }
}

const ORIGINS: [(i64, i64); 8] =
    [(0, 0), (1, 1), (-1, -1), (5, -7), (-100, 100), (3000, -3000), (2_000_000, 1_000_000), (-2_000_000_000, 2_000_000_000)];

#[test]
fn coords_on_circle_matches() {
    let _engine = engine();
    let mut inputs: Vec<(Coord, i64, i64, bool)> = Vec::new();
    for &(column, row) in &ORIGINS {
        for radius in -5..=40 {
            for limit in [0, 1, 2, 3, 5, 7, 10, 50, 100, 7 * radius.max(1)] {
                for unique in [false, true] {
                    inputs.push((Coord::new(column, row), radius, limit, unique));
                }
            }
        }
    }
    let mut cases = Cases::new(21);
    for _ in 0..3000 {
        inputs.push((cases.coord(500), cases.range(-10, 150), cases.range(0, 800), cases.next_u64() & 1 == 1));
    }
    for &(origin, radius, limit, unique) in &inputs {
        arena_reset();
        let expected = packed(&geometry::find_coords_on_circle(origin, radius, limit, unique));
        // SAFETY: the thunk marshals plain integers.
        let got = unsafe { ttfx_test_geometry_coords_on_circle(pack(origin), radius, limit, unique as u32) }.coords();
        assert_eq!(got, expected, "find_coords_on_circle({origin:?}, {radius}, {limit}, {unique})");
    }
}

#[test]
fn coords_in_circle_matches_list_and_stream() {
    let _engine = engine();
    let mut inputs: Vec<(Coord, i64)> = Vec::new();
    for &(column, row) in &ORIGINS {
        for diameter in -5..=80 {
            inputs.push((Coord::new(column, row), diameter));
        }
    }
    let mut cases = Cases::new(22);
    for _ in 0..600 {
        inputs.push((cases.coord(1000), cases.range(-20, 300)));
    }
    for &(center, diameter) in &inputs {
        arena_reset();
        let expected = packed(&geometry::find_coords_in_circle(center, diameter));
        // SAFETY: plain integers in, an arena list out.
        let got = unsafe { ttfx_test_geometry_coords_in_circle(pack(center), diameter) }.coords();
        assert_eq!(got, expected, "find_coords_in_circle({center:?}, {diameter})");
        // the streaming ellipse visits the same cells in the same order
        let mut state = [0u64; 16];
        let mut streamed = Vec::new();
        // SAFETY: the state buffer is larger than CIRCLE_ITER_size.
        unsafe {
            ttfx_test_geometry_circle_iter_init(state.as_mut_ptr(), pack(center), diameter);
            let mut word = 0u64;
            while ttfx_test_geometry_circle_iter_next(state.as_mut_ptr(), &mut word) != 0 {
                streamed.push(unpack(word));
            }
        }
        assert_eq!(streamed, expected, "coords_in_circle({center:?}, {diameter})");
    }
}

#[test]
fn coords_in_and_on_rect_match() {
    let _engine = engine();
    for &(column, row) in &ORIGINS {
        let origin = Coord::new(column, row);
        for distance in -3..=40 {
            arena_reset();
            let expected = packed(&geometry::find_coords_in_rect(origin, distance));
            // SAFETY: plain integers in, an arena list out.
            let got = unsafe { ttfx_test_geometry_coords_in_rect(pack(origin), distance) }.coords();
            assert_eq!(got, expected, "find_coords_in_rect({origin:?}, {distance})");
        }
        for half_width in -4..=15 {
            for half_height in -4..=15 {
                arena_reset();
                let expected = packed(&geometry::find_coords_on_rect(origin, half_width, half_height));
                // SAFETY: as above.
                let got = unsafe { ttfx_test_geometry_coords_on_rect(pack(origin), half_width, half_height) }.coords();
                assert_eq!(got, expected, "find_coords_on_rect({origin:?}, {half_width}, {half_height})");
            }
        }
    }
    let mut cases = Cases::new(23);
    for _ in 0..300 {
        let origin = cases.coord(100_000);
        arena_reset();
        let distance = cases.range(-5, 120);
        let expected = packed(&geometry::find_coords_in_rect(origin, distance));
        // SAFETY: as above.
        let got = unsafe { ttfx_test_geometry_coords_in_rect(pack(origin), distance) }.coords();
        assert_eq!(got, expected, "find_coords_in_rect({origin:?}, {distance})");
        let (half_width, half_height) = (cases.range(-5, 300), cases.range(-5, 300));
        let expected = packed(&geometry::find_coords_on_rect(origin, half_width, half_height));
        // SAFETY: as above.
        let got = unsafe { ttfx_test_geometry_coords_on_rect(pack(origin), half_width, half_height) }.coords();
        assert_eq!(got, expected, "find_coords_on_rect({origin:?}, {half_width}, {half_height})");
    }
}

#[test]
fn length_of_line_matches_bits() {
    let _engine = engine();
    let mut pairs: Vec<(Coord, Coord)> = Vec::new();
    for &(c1, r1) in &ORIGINS {
        for &(c2, r2) in &ORIGINS {
            pairs.push((Coord::new(c1, r1), Coord::new(c2, r2)));
        }
    }
    let mut cases = Cases::new(31);
    for _ in 0..20_000 {
        pairs.push((cases.coord(300), cases.coord(300)));
    }
    for _ in 0..5_000 {
        pairs.push((cases.coord(1_000_000_000), cases.coord(1_000_000_000)));
    }
    for &(a, b) in &pairs {
        for double in [false, true] {
            let expected = geometry::find_length_of_line(a, b, double);
            // SAFETY: plain values in, a float out.
            let got = unsafe { ttfx_test_geometry_length_of_line(pack(a), pack(b), double as u32) };
            assert_eq!(got.to_bits(), expected.to_bits(), "find_length_of_line({a:?}, {b:?}, {double})");
        }
    }
}

#[test]
fn extrapolate_along_ray_matches() {
    let _engine = engine();
    let mut cases = Cases::new(32);
    let mut pairs: Vec<(Coord, Coord)> = Vec::new();
    for &(c1, r1) in &ORIGINS {
        for &(c2, r2) in &ORIGINS {
            pairs.push((Coord::new(c1, r1), Coord::new(c2, r2)));
        }
    }
    for _ in 0..3000 {
        pairs.push((cases.coord(300), cases.coord(300)));
    }
    for _ in 0..500 {
        let origin = cases.coord(300);
        pairs.push((origin, origin));
    }
    let offsets = [
        0.0,
        -0.0,
        1.0,
        -1.0,
        0.5,
        -0.5,
        2.5,
        7.25,
        -3.75,
        100.0,
        -100.0,
        1e-9,
        -1e-9,
        1e12,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::NAN,
    ];
    for &(origin, target) in &pairs {
        let base = geometry::find_length_of_line(origin, target, false);
        for offset in offsets.iter().copied().chain([-base, -base * 0.5, base * 3.0, cases.uniform(-50.0, 50.0)]) {
            let expected = unpack(pack(geometry::extrapolate_along_ray(origin, target, offset)));
            // SAFETY: plain values in and out.
            let got = unpack(unsafe { ttfx_test_geometry_extrapolate_along_ray(pack(origin), pack(target), offset) });
            assert_eq!(got, expected, "extrapolate_along_ray({origin:?}, {target:?}, {offset:e})");
        }
    }
}

const TS: [f64; 22] = [
    0.0,
    0.1,
    0.2,
    0.3,
    0.4,
    0.5,
    0.6,
    0.7,
    0.8,
    0.9,
    1.0,
    0.25,
    1.0 / 3.0,
    2.0 / 3.0,
    -0.5,
    1.5,
    2.0,
    1e-3,
    0.999_999,
    1e-300,
    f64::NAN,
    f64::INFINITY,
];

/// Bezier inputs: a start, 0 to 6 control points and an end, with the
/// degenerate shapes first.
fn bezier_inputs() -> Vec<(Coord, Vec<Coord>, Coord)> {
    let mut inputs: Vec<(Coord, Vec<Coord>, Coord)> = Vec::new();
    for &(column, row) in &ORIGINS[..6] {
        let p = Coord::new(column, row);
        let q = Coord::new(column + 17, row - 9);
        for count in 0..=6 {
            inputs.push((p, vec![p; count], p));
            inputs.push((p, vec![p; count], q));
            inputs.push((p, vec![q; count], q));
            inputs.push((p, (0..count).map(|i| Coord::new(column + i as i64 * 3, row + i as i64 * 3)).collect(), q));
        }
    }
    let mut cases = Cases::new(33);
    for _ in 0..3000 {
        let count = cases.range(0, 6) as usize;
        inputs.push((cases.coord(500), (0..count).map(|_| cases.coord(500)).collect(), cases.coord(500)));
    }
    for _ in 0..500 {
        let count = cases.range(0, 3) as usize;
        inputs.push((cases.coord(1_000_000), (0..count).map(|_| cases.coord(1_000_000)).collect(), cases.coord(1_000_000)));
    }
    inputs
}

#[test]
fn coord_on_bezier_curve_and_line_match() {
    let _engine = engine();
    for (start, control, end) in bezier_inputs() {
        let words: Vec<u64> = control.iter().map(|&c| pack(c)).collect();
        for t in TS {
            let expected = unpack(pack(geometry::find_coord_on_bezier_curve(start, &control, end, t)));
            // SAFETY: the control array has words.len() entries.
            let got = unpack(unsafe {
                ttfx_test_geometry_coord_on_bezier_curve(pack(start), words.as_ptr(), words.len() as u64, pack(end), t)
            });
            assert_eq!(got, expected, "find_coord_on_bezier_curve({start:?}, {control:?}, {end:?}, {t:e})");
            if control.is_empty() {
                let expected = unpack(pack(geometry::find_coord_on_line(start, end, t)));
                // SAFETY: plain values in and out.
                let got = unpack(unsafe { ttfx_test_geometry_coord_on_line(pack(start), pack(end), t) });
                assert_eq!(got, expected, "find_coord_on_line({start:?}, {end:?}, {t:e})");
            }
        }
    }
}

#[test]
fn length_of_bezier_curve_matches_bits() {
    let _engine = engine();
    for (start, control, end) in bezier_inputs() {
        let words: Vec<u64> = control.iter().map(|&c| pack(c)).collect();
        let expected = geometry::find_length_of_bezier_curve(start, &control, end);
        // SAFETY: the control array has words.len() entries.
        let got = unsafe {
            ttfx_test_geometry_length_of_bezier_curve(pack(start), words.as_ptr(), words.len() as u64, pack(end))
        };
        assert_eq!(got.to_bits(), expected.to_bits(), "find_length_of_bezier_curve({start:?}, {control:?}, {end:?})");
    }
}

#[test]
fn normalized_distance_from_center_matches() {
    let _engine = engine();
    let mut rectangles: Vec<(i64, i64, i64, i64)> = Vec::new();
    for bottom in [1, 0, -3, 5] {
        for height in 0..=12 {
            for left in [1, 0, -4, 7] {
                for width in 0..=20 {
                    rectangles.push((bottom, bottom + height, left, left + width));
                }
            }
        }
    }
    let mut cases = Cases::new(34);
    for _ in 0..200 {
        let (bottom, left) = (cases.range(-50, 50), cases.range(-50, 50));
        rectangles.push((bottom, bottom + cases.range(-2, 60), left, left + cases.range(-2, 200)));
    }
    for &(bottom, top, left, right) in &rectangles {
        for column in left - 2..=right + 2 {
            for row in bottom - 2..=top + 2 {
                let coord = Coord::new(column, row);
                let expected = geometry::find_normalized_distance_from_center(bottom, top, left, right, coord);
                let mut value = 0.0f64;
                // SAFETY: the out pointer is a live f64.
                let inside = unsafe { ttfx_test_geometry_normalized_distance(bottom, top, left, right, pack(coord), &mut value) };
                match expected {
                    Ok(distance) => {
                        assert_eq!(inside, 1, "inside ({bottom}, {top}, {left}, {right}) {coord:?}");
                        assert_eq!(value.to_bits(), distance.to_bits(), "distance ({bottom}, {top}, {left}, {right}) {coord:?}");
                    }
                    Err(message) => {
                        assert_eq!(inside, 0, "outside ({bottom}, {top}, {left}, {right}) {coord:?}");
                        assert_eq!(message, "Coordinate is not within the rectangle.");
                    }
                }
            }
        }
    }
}

// ------------------------------------------------------------------- color

use ttfx::engine::animation::Animation;
use ttfx::utils::graphics::{self, Color};

#[repr(C)]
struct ColorResult {
    color: u64,
    ok: u64,
}

extern "C" {
    fn ttfx_test_color_adjust_color_brightness(color: u64, brightness: f64) -> u64;
    fn ttfx_test_color_shift_color_towards(color: u64, target: u64, factor: f64) -> ColorResult;
    fn ttfx_test_color_random_color(state: *mut [u64; 4]) -> u64;
}

fn rgb(r: u8, g: u8, b: u8) -> Color {
    Color::from_hex(&format!("{r:02x}{g:02x}{b:02x}")).unwrap()
}

/// The plain RGB word of a color.
fn rgb_word(color: &Color) -> u64 {
    let (r, g, b) = color.rgb_ints();
    (r as u64) << 16 | (g as u64) << 8 | b as u64
}

/// The engine's word for a color, xterm code included (asm/ttfx.inc).
fn color_word(color: &Color) -> u64 {
    match color.xterm_color {
        Some(code) => rgb_word(color) | (code as u64) << 32 | 1 << 40,
        None => rgb_word(color),
    }
}

/// Every channel value in every position, with a spread of companions.
fn channel_sweep(cases: &mut Cases) -> Vec<Color> {
    let mut colors = Vec::new();
    for value in 0..=255u8 {
        let random = (cases.range(0, 255) as u8, cases.range(0, 255) as u8);
        for others in [(0, 0), (255, 255), (128, 128), (64, 192), (value, 255 - value), (value, value), random] {
            colors.push(rgb(value, others.0, others.1));
            colors.push(rgb(others.0, value, others.1));
            colors.push(rgb(others.0, others.1, value));
        }
    }
    colors
}

#[test]
fn adjust_color_brightness_matches() {
    let _engine = engine();
    let brightnesses = [
        0.0,
        0.1,
        0.2,
        0.3,
        0.5,
        0.55,
        0.65,
        0.75,
        0.9,
        0.999,
        1.0,
        1.001,
        1.25,
        1.5,
        1.7,
        2.0,
        3.0,
        10.0,
        -0.5,
        -1.0,
        1.0 / 3.0,
        2.0 / 3.0,
        1e-9,
        1e9,
        f64::NAN,
        f64::INFINITY,
        f64::NEG_INFINITY,
    ];
    let mut cases = Cases::new(41);
    let mut colors = channel_sweep(&mut cases);
    for code in 0..=255u8 {
        colors.push(Color::from_xterm(code));
    }
    for color in &colors {
        for brightness in brightnesses.iter().copied().chain([cases.uniform(0.0, 3.0)]) {
            let expected = Animation::adjust_color_brightness(color, brightness);
            assert!(expected.xterm_color.is_none());
            // SAFETY: plain values in and out.
            let got = unsafe { ttfx_test_color_adjust_color_brightness(color_word(color), brightness) };
            assert_eq!(got, rgb_word(&expected), "adjust_color_brightness({:?}, {brightness:e})", color.rgb_color);
        }
    }
}

#[test]
fn shift_color_towards_matches() {
    let _engine = engine();
    let factors = [
        0.0,
        0.1,
        0.25,
        1.0 / 3.0,
        0.5,
        0.75,
        0.9,
        0.999,
        1.0,
        1.000_000_1,
        1.5,
        2.0,
        -0.5,
        -1.0,
        0.01,
        1e-9,
        3.99,
        4.0,
        17.0,
        -17.0,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::NAN,
    ];
    let mut cases = Cases::new(42);
    let colors = channel_sweep(&mut cases);
    let mut checked = 0usize;
    for color in &colors {
        let (r, g, b) = color.rgb_ints();
        let random = rgb(cases.range(0, 255) as u8, cases.range(0, 255) as u8, cases.range(0, 255) as u8);
        for target in [rgb(0, 0, 0), rgb(255, 255, 255), rgb(255 - r, 255 - g, 255 - b), rgb(r, g, b), random] {
            for factor in factors {
                // Rust panics (Color::from_hex on a '-') when a channel goes
                // negative, so predict the channels with the same arithmetic
                // and only call it when none does.
                let channel = |start: u8, end: u8| {
                    let (start, end) = (start as f64 / 255.0, end as f64 / 255.0);
                    ((start + (end - start) * factor) * 255.0) as i64
                };
                let (tr, tg, tb) = target.rgb_ints();
                let channels = [channel(r, tr), channel(g, tg), channel(b, tb)];
                let expected = if channels.iter().any(|&c| c < 0) {
                    None
                } else {
                    match graphics::shift_color_towards(color, &target, factor) {
                        Ok(shifted) if shifted.rgb_color.len() == 6 => Some(rgb_word(&shifted)),
                        _ => None, // a 7-digit pseudo-color or the hex error
                    }
                };
                // SAFETY: plain values in, a two-word struct out.
                let got = unsafe { ttfx_test_color_shift_color_towards(color_word(color), color_word(&target), factor) };
                match expected {
                    Some(word) => {
                        assert_eq!((got.ok, got.color), (1, word), "shift_color_towards({:?}, {:?}, {factor:e})", color.rgb_color, target.rgb_color);
                        checked += 1;
                    }
                    None => assert_eq!(got.ok, 0, "shift_color_towards({:?}, {:?}, {factor:e}) must fail", color.rgb_color, target.rgb_color),
                }
            }
        }
    }
    assert!(checked > 100_000, "only {checked} in-range cases");
}

#[test]
fn random_color_matches_values_and_state() {
    let _engine = engine();
    for seed in 0..200u64 {
        let mut rust = Rng::seeded(seed);
        let mut state = rust.state();
        for _ in 0..200 {
            let expected = graphics::random_color(&mut rust);
            // SAFETY: the thunk reads and writes exactly four words.
            let got = unsafe { ttfx_test_color_random_color(&mut state) };
            assert_eq!(got, rgb_word(&expected), "random_color (seed {seed})");
            assert_eq!(state, rust.state());
        }
    }
}
