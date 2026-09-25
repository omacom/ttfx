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
