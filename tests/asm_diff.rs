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
